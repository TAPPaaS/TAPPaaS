// zonemodify.ts — `network-manager modify <zone> --set field=value` (#538).
//
// ADR-020 D6: the declared-field change model is manager-agnostic, and
// network-manager is its second implementer. Before this, a zone's POLICY
// fields — access-to, pinhole-allowed-from, description — could only be changed
// by hand-editing zones.json or by delete-and-re-add, which is exactly the
// anti-pattern ADR-014 D1 set out to close. Every sibling manager presents
// `modify`; this is that shape, over the same change model module-manager uses.
//
// WHERE THE MANIFEST LIVES, and why it is not a manifest. A module field's
// change class is keyed by the (field, SERVICE) pair, because `node` costs one
// thing under cluster:vm and another under cluster:ha — hence a per-service
// fields.json. A zone field has exactly ONE owner, network-manager, so there is
// no pair to disambiguate and no ambiguity for a separate file to resolve. The
// class therefore lives with the field definition, in schemas/zones-fields.json
// as `changeClass`. Same taxonomy (lib/ts/src/service-fields.ts), same pre-gate
// rules, one less indirection.
//
// The pre-gate follows ADR-020 D2 step 0 exactly:
//   - `immutable` is refused before anything is written — a zone's VLAN or
//     subnet cannot change under its guests;
//   - `manual` is refused too, but differently: those fields HAVE a verb
//     (enable/disable/manual, bind), and that verb carries guards a generic
//     --set would bypass. The message names it.
//   - a mixed --set is rejected WHOLE, so zones.json and the planes never move
//     apart.
//
// Like every other zones.json mutation verb here, this deliberately does NOT
// reconcile: it authors the change and tells the operator how to apply it.

import { CHANGE_CLASSES } from "../../../lib/ts/src/service-fields";
import { ZonesDoc } from "./types";

export interface ZoneFieldSchema {
  type?: string;
  changeClass?: string;
  changeNote?: string;
}
export type ZonesFieldsSchema = Record<string, ZoneFieldSchema>;

export interface SetRequest {
  field: string;
  value: string;
}

export interface SetRejection {
  field: string;
  reason: string;
}

export interface ParsedSet extends SetRequest {
  // The JSON value to write, coerced from the schema's declared type.
  parsed: unknown;
  changeClass: string;
}

export type ZoneSetPlan =
  | { ok: true; plan: ParsedSet[] }
  | { ok: false; rejections: SetRejection[] };

export function parseSetArg(arg: string): SetRequest | null {
  const eq = arg.indexOf("=");
  if (eq <= 0) return null;
  return { field: arg.slice(0, eq), value: arg.slice(eq + 1) };
}

// Coerce a --set value to the type zones-fields.json declares. An array field
// accepts either JSON (["a","b"]) or the comma/space list an operator is far
// more likely to type; anything else stays a string. Getting this wrong would
// write "[\"lan\"]" as a string into access-to, which reconcile would then
// treat as one zone named `["lan"]`.
export function coerce(value: string, type: string | undefined): { ok: true; value: unknown } | { ok: false; why: string } {
  const t = (type ?? "string").toLowerCase();
  if (t === "array") {
    const trimmed = value.trim();
    if (trimmed.startsWith("[")) {
      try {
        const v = JSON.parse(trimmed);
        if (!Array.isArray(v)) return { ok: false, why: "is a list field, but that JSON is not an array" };
        return { ok: true, value: v };
      } catch (e) {
        return { ok: false, why: `is a list field and that is not valid JSON: ${(e as Error).message}` };
      }
    }
    if (trimmed === "") return { ok: true, value: [] };
    return { ok: true, value: trimmed.split(/[,\s]+/).filter((s) => s !== "") };
  }
  if (t === "integer" || t === "number") {
    if (!/^-?\d+$/.test(value.trim())) return { ok: false, why: `is numeric, but '${value}' is not a number` };
    return { ok: true, value: Number(value.trim()) };
  }
  if (t === "boolean") {
    const s = value.trim().toLowerCase();
    if (s === "true") return { ok: true, value: true };
    if (s === "false") return { ok: true, value: false };
    return { ok: false, why: `is boolean, but '${value}' is neither true nor false` };
  }
  return { ok: true, value };
}

// The static pre-gate. Refuses before anything is written; rejects whole.
export function preGateZoneSet(
  zone: string,
  requests: SetRequest[],
  schema: ZonesFieldsSchema,
): ZoneSetPlan {
  const rejections: SetRejection[] = [];
  const plan: ParsedSet[] = [];

  if (Object.keys(schema).length === 0) {
    return {
      ok: false,
      rejections: [
        {
          field: requests.map((r) => r.field).join(", "),
          reason: "zones-fields.json is not readable — without it no field can be validated or classified",
        },
      ],
    };
  }

  for (const req of requests) {
    const spec = schema[req.field];
    if (!spec) {
      rejections.push({
        field: req.field,
        reason: "not a field zones-fields.json declares — check the spelling",
      });
      continue;
    }

    const cls = spec.changeClass ?? "";
    const meta = CHANGE_CLASSES[cls];
    if (!meta) {
      rejections.push({
        field: req.field,
        reason:
          `has no declared changeClass in zones-fields.json, so what changing it costs is unknown — ` +
          `declare one before it can be set through a verb (ADR-020 D6)`,
      });
      continue;
    }

    // `manual` here means "there is a verb for this, with guards a generic set
    // would skip" — so the refusal names the verb rather than just saying no.
    if (cls === "manual") {
      rejections.push({
        field: req.field,
        reason: `${spec.changeNote ?? "has a dedicated verb; use it instead of --set"}`,
      });
      continue;
    }
    if (meta.preGate || !meta.applies) {
      rejections.push({
        field: req.field,
        reason:
          `${cls} — ${meta.summary}. ${spec.changeNote ?? ""} ` +
          `Use 'network-manager delete ${zone}' then 'add' to change it.`.trim(),
      });
      continue;
    }

    const c = coerce(req.value, spec.type);
    if (!c.ok) {
      rejections.push({ field: req.field, reason: `${req.field} ${c.why}` });
      continue;
    }
    plan.push({ ...req, parsed: c.value, changeClass: cls });
  }

  if (rejections.length > 0) return { ok: false, rejections };
  return { ok: true, plan };
}

// Apply the plan to the in-memory document. The caller saves.
export function applyZoneSet(doc: ZonesDoc, zone: string, plan: ParsedSet[]): void {
  const raw = doc.raw[zone] as Record<string, unknown>;
  for (const p of plan) raw[p.field] = p.parsed;
}
