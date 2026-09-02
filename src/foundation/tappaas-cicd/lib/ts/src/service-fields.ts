// service-fields.ts — the per-service field manifest (ADR-020 D3/D4).
//
// A service manifest lives at `services/<service>/fields.json` inside the
// PROVIDER module's source tree and declares, for every field that service owns
// (i.e. every module-fields.json field whose `usedBy` names the provider's
// `<module>:<service>` coordinate), TWO things:
//
//   1. its CHANGE CLASS — what changing the field after install costs, and
//   2. how the change is APPLIED — a batched `set`, a dedicated hook script, a
//      composite it contributes to, or nothing at all.
//
// SHARED via lib/ts because the frame is manager-agnostic (ADR-020 D6/Q7):
// module-manager is the first implementer, network-manager the second. Each
// manager supplies its own per-service manifests; the vocabulary, the document
// shape and the lint below are common.
//
// PURE: this file has no filesystem, no cluster and no manager imports. Callers
// hand it a parsed JSON document; it hands back a typed manifest plus the
// findings of a structural lint. That is what lets `validate` check a manifest
// statically, offline, with no tree (ADR-020 D5: validate reads schema + config,
// touches nothing).

// ── the change-class taxonomy (ADR-020 D3) ─────────────────────────────
//
// Drawn from what cluster/services/vm/update-service.sh already encoded before
// this ADR named it. Each class carries the three properties the manager needs
// to plan a change, so no caller re-derives them from the class NAME:
//
//   applies    — may the converge apply this field at all?
//   preGate    — does `modify --set` reject it STATICALLY, before writing
//                config (ADR-020 D2 step 0)? True only where the refusal needs
//                no live state: immutable and recreate. A grow-only shrink or a
//                not-live-OK migrate is only knowable at apply time, so those
//                refuse in the converge instead.
//   disruptive — can applying it require disruption (guest reboot / offline
//                migrate)? Those need authorization: `modify --force`, or
//                `rebootOk` in the ADR-017 scheduled pass (ADR-020 D8).
//   rank       — the ESCALATION order, used to compose a composite's ceiling
//                from its inputs (see lintServiceFieldManifest) and, from P3,
//                to pick a composite's EFFECTIVE class from the inputs that
//                actually changed: two changed NIC inputs where only the MAC
//                moved stay in-place, exactly as cluster:vm behaves today.
export interface ChangeClassSpec {
  applies: boolean;
  preGate: boolean;
  disruptive: boolean;
  rank: number;
  summary: string;
}

export const CHANGE_CLASSES: Readonly<Record<string, ChangeClassSpec>> = {
  immutable: {
    applies: false,
    preGate: true,
    disruptive: false,
    rank: 5,
    summary: "cannot change in place — requires delete + reinstall",
  },
  "in-place": {
    applies: true,
    preGate: false,
    disruptive: false,
    rank: 1,
    summary: "safe live change, no downtime",
  },
  "in-place-reboot": {
    applies: true,
    preGate: false,
    disruptive: true,
    rank: 3,
    summary: "live change that needs a guest reboot to take effect",
  },
  "grow-only": {
    applies: true,
    preGate: false,
    disruptive: false,
    rank: 1,
    summary: "one-way — grow applies, shrink is refused at apply time",
  },
  migrate: {
    applies: true,
    preGate: false,
    disruptive: true,
    rank: 3,
    summary: "relocates or rebuilds runtime state (ADR-019)",
  },
  manual: {
    applies: false,
    preGate: false,
    disruptive: false,
    rank: 2,
    summary: "reconcilable only by an operator action the tool will not take silently",
  },
  recreate: {
    applies: false,
    preGate: true,
    disruptive: false,
    rank: 4,
    summary: "takes effect only at guest creation",
  },
};

// The most-escalated of a set of classes — the composite ceiling rule, and (from
// P3) the effective class of a composite whose inputs did not all change.
export function worstClass(classes: string[]): string | null {
  let best: string | null = null;
  for (const c of classes) {
    const spec = CHANGE_CLASSES[c];
    if (!spec) continue;
    if (best === null || spec.rank > CHANGE_CLASSES[best].rank) best = c;
  }
  return best;
}

export const CHANGE_CLASS_NAMES = Object.keys(CHANGE_CLASSES);

export type ChangeClass = keyof typeof CHANGE_CLASSES;

export function isChangeClass(s: string): boolean {
  return Object.prototype.hasOwnProperty.call(CHANGE_CLASSES, s);
}

// ── the apply modes ────────────────────────────────────────────────────
//
//   set       — the runner batches it into ONE provider-level set call
//               (`qm set --cores 8 --memory 4096 …`), preserving the single
//               batched write cluster:vm has always done.
//   hook      — dispatched to `services/<svc>/<hook>` with the uniform hook CLI
//               (ADR-020 D7): --field/--desired/--actual [--check] [--force].
//   composite — the field is one INPUT of a derived value (net0 is built from
//               bridge0/zone0/mac0/trunks0); the composite carries the class,
//               the hook and the side effects, and the field points at it.
//   none      — never applied by the converge (immutable / recreate / manual).
export const APPLY_MODES = ["set", "hook", "composite", "none"] as const;
export type ApplyMode = (typeof APPLY_MODES)[number];

// ── the normalizer vocabulary ──────────────────────────────────────────
//
// Normalization is DECLARED here and performed ONCE, in the manager, on BOTH
// sides of the diff (ADR-020 D7) — this is what kills the vm-net.sh ↔
// inspect.ts duplication. A service never normalizes; it reports raw and
// applies what it is handed.
export const NORMALIZERS = [
  "string", // trim only (the default)
  "integer", // numeric compare, so "8" == 8
  "boolean", // true/false/yes/no/1/0 → true|false
  "tags", // lowercase, split on , ; or space, dedupe, sort, join with ';'
  "trunks", // zone-name list → resolved VLAN id list, sorted
  "vlan", // VLAN tag, absent == 0
  "size", // disk size with a unit suffix → bytes, so "8G" == "8192M"
  "optional", // the "NONE" sentinel means absent, so it equals a missing value
] as const;
export type Normalizer = (typeof NORMALIZERS)[number];

// ── the side-effect vocabulary ─────────────────────────────────────────
//
// Declared per entry so the runner can SEQUENCE them once across the whole
// drift record: net0 and net1 both changing must still produce exactly one
// reboot and one DNS pass (the ordering cluster:vm hand-rolls today).
export const SIDE_EFFECTS = ["reboot", "dns", "wait-ip", "ha-repoint"] as const;
export type SideEffect = (typeof SIDE_EFFECTS)[number];

// ── the document ───────────────────────────────────────────────────────

export interface FieldEntry {
  class: string;
  apply?: ApplyMode;
  // Key under which report-service.sh reports this field's ACTUAL value.
  // Defaults to the field name; cluster:vm needs it because Proxmox spells
  // `cputype` as `cpu`, `vmtag` as `tags` and `vmname` as `name`.
  liveKey?: string;
  // apply:"set" — the provider flag. Defaults to `--<liveKey>`.
  setFlag?: string;
  // apply:"hook" — the script, relative to the service directory.
  hook?: string;
  // apply:"composite" — the composite this field is an input of.
  composite?: string;
  normalize?: Normalizer;
  sideEffects?: SideEffect[];
  // When the module does NOT declare this field, is its module-fields.json
  // default DESIRED STATE, or merely an install-time seed? Default true.
  //
  // This is the declared form of the `__none__` sentinel every converge script
  // hand-rolls today: `cluster:vm/update-service.sh` reads an undeclared
  // `diskSize` as "leave the disk alone", not as "resize it to the schema's
  // 8G". Both readings are defensible; what is not defensible is the reading
  // living only inside one bash script, where the drift report cannot see it.
  // The resolver still resolves the default (so `resolve` and `inspect` show
  // the effective value); this says the CONVERGE must not act on it unless the
  // module asked for it — the distinction `ResolvedField.literal` carries.
  defaultIsDesired?: boolean;
  note?: string;
}

// A derived apply unit assembled from several declared fields. It owns the
// class, the hook and the side effects; its input fields point at it.
export interface CompositeEntry {
  class: string;
  apply?: ApplyMode;
  liveKey?: string;
  setFlag?: string;
  hook?: string;
  inputs: string[];
  normalize?: Normalizer;
  sideEffects?: SideEffect[];
  defaultIsDesired?: boolean;
  note?: string;
}

export interface ServiceFieldManifest {
  service: string;
  description?: string;
  fields: Record<string, FieldEntry>;
  composites: Record<string, CompositeEntry>;
}

export interface ManifestFinding {
  severity: "error" | "warning";
  message: string;
}

// Parse a manifest document. Returns null (with a finding) when the document is
// not a manifest at all; a structurally-usable manifest otherwise, with any
// per-entry problems reported in `findings` — one bad entry must not hide the
// rest.
export function parseServiceFieldManifest(
  doc: unknown,
  findings: ManifestFinding[],
): ServiceFieldManifest | null {
  if (doc === null || typeof doc !== "object" || Array.isArray(doc)) {
    findings.push({ severity: "error", message: "fields.json is not a JSON object" });
    return null;
  }
  const raw = doc as Record<string, unknown>;
  const service = typeof raw.service === "string" ? raw.service : "";
  if (!service) {
    findings.push({
      severity: "error",
      message: "fields.json has no 'service' — it must name its own '<module>:<service>' coordinate",
    });
  }
  const fields = pickObject(raw.fields);
  if (!fields) {
    findings.push({ severity: "error", message: "fields.json has no 'fields' object" });
    return null;
  }
  const composites = pickObject(raw.composites) ?? {};

  const out: ServiceFieldManifest = {
    service,
    description: typeof raw.description === "string" ? raw.description : undefined,
    fields: {},
    composites: {},
  };
  for (const [name, v] of Object.entries(fields)) {
    const e = pickObject(v);
    if (!e) {
      findings.push({ severity: "error", message: `field '${name}': entry is not an object` });
      continue;
    }
    out.fields[name] = e as unknown as FieldEntry;
  }
  for (const [name, v] of Object.entries(composites)) {
    const e = pickObject(v);
    if (!e) {
      findings.push({ severity: "error", message: `composite '${name}': entry is not an object` });
      continue;
    }
    const c = e as unknown as CompositeEntry;
    out.composites[name] = { ...c, inputs: Array.isArray(c.inputs) ? c.inputs : [] };
  }
  return out;
}

function pickObject(v: unknown): Record<string, unknown> | null {
  return v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
}

// The apply mode an entry effectively has: explicit, else inferred from the
// class (a class that never applies is "none"; anything else defaults to a
// batched "set"). Keeping the inference HERE means the manifests stay terse and
// every consumer reads the same effective value.
export function effectiveApply(e: FieldEntry | CompositeEntry): ApplyMode {
  if (e.apply) return e.apply;
  const spec = CHANGE_CLASSES[e.class];
  if (spec && !spec.applies) return "none";
  return "set";
}

// ── the lint (ADR-020 P0) ──────────────────────────────────────────────

export interface ManifestLintOptions {
  // The `<module>:<service>` coordinate this manifest was loaded for, so a
  // manifest whose own `service` disagrees is caught.
  coordinate: string;
  // Every field module-fields.json says this coordinate OWNS (its usedBy set).
  // Coverage is checked against exactly this set.
  ownedFields: string[];
  // Every field module-fields.json declares at all — a manifest entry naming
  // something outside this set is a typo, not a field.
  declaredFields: string[];
}

// Structural lint of one manifest. This is the check ADR-020 P0 adds to
// `validate`: a `usedBy` field with no manifest entry, or an entry naming a
// class the taxonomy does not define, must ERROR — statically, with no cluster
// contact, in the spirit of #549 (validate enforces what the runtime enforces).
export function lintServiceFieldManifest(
  m: ServiceFieldManifest,
  opts: ManifestLintOptions,
  findings: ManifestFinding[],
): void {
  const err = (message: string): void => void findings.push({ severity: "error", message });
  const declared = new Set(opts.declaredFields);

  if (m.service && m.service !== opts.coordinate) {
    err(`fields.json declares service '${m.service}' but lives under '${opts.coordinate}'`);
  }

  // Entries + composites share almost every rule; check them through one pass
  // so a composite cannot quietly escape the class/hook/normalize vocabulary.
  const entries: [string, FieldEntry | CompositeEntry, boolean][] = [
    ...Object.entries(m.fields).map(
      ([n, e]) => [n, e, false] as [string, FieldEntry | CompositeEntry, boolean],
    ),
    ...Object.entries(m.composites).map(
      ([n, e]) => [n, e, true] as [string, FieldEntry | CompositeEntry, boolean],
    ),
  ];

  for (const [name, e, isComposite] of entries) {
    const what = isComposite ? `composite '${name}'` : `field '${name}'`;

    if (typeof e.class !== "string" || !isChangeClass(e.class)) {
      err(
        `${what}: unknown change class '${String(e.class)}' — must be one of: ${CHANGE_CLASS_NAMES.join(" ")}`,
      );
      continue; // every later rule keys off a valid class
    }
    const spec = CHANGE_CLASSES[e.class];

    if (e.apply !== undefined && !(APPLY_MODES as readonly string[]).includes(e.apply)) {
      err(`${what}: unknown apply mode '${e.apply}' — must be one of: ${APPLY_MODES.join(" ")}`);
      continue;
    }
    const apply = effectiveApply(e);

    // A class that never applies must not declare a way to apply it: an
    // immutable field with a hook reads as "we can change this", and the
    // pre-gate would refuse it anyway. State the contradiction here rather
    // than letting the converge silently ignore the hook.
    if (!spec.applies && apply !== "none") {
      err(
        `${what}: class '${e.class}' is never applied by the converge, but declares apply:'${apply}' — use apply:"none"`,
      );
    }
    if (spec.applies && apply === "none") {
      err(`${what}: class '${e.class}' is applicable, but declares apply:"none"`);
    }

    if (apply === "hook" && !e.hook) {
      err(`${what}: apply:"hook" requires a 'hook' script name`);
    }
    if (apply !== "hook" && e.hook) {
      err(`${what}: declares hook '${e.hook}' but apply is '${apply}'`);
    }

    if (isComposite) {
      const c = e as CompositeEntry;
      if (!Array.isArray(c.inputs) || c.inputs.length === 0) {
        err(`${what}: a composite must list the fields it is assembled from ('inputs')`);
      } else {
        const inputClasses: string[] = [];
        for (const input of c.inputs) {
          const fe = m.fields[input];
          if (!fe) {
            err(`${what}: input '${input}' has no field entry in this manifest`);
            continue;
          }
          if (fe.composite !== name) {
            err(`${what}: input '${input}' does not point back at it (expected composite:'${name}')`);
          }
          if (typeof fe.class === "string" && isChangeClass(fe.class)) inputClasses.push(fe.class);
        }
        // A composite's declared class is its CEILING: the worst its inputs can
        // cost. Deriving it from the inputs (rather than trusting the author)
        // is what keeps "changing mac0 does not reboot the guest, changing
        // zone0 does" true after the P3 split — the runner picks the effective
        // class from the inputs that actually drifted, and it can only ever be
        // at or below this ceiling.
        const ceiling = worstClass(inputClasses);
        if (ceiling !== null && ceiling !== e.class) {
          err(
            `${what}: class '${e.class}' does not match its inputs — the most-escalated input class is '${ceiling}'`,
          );
        }
      }
    } else {
      const f = e as FieldEntry;
      if (!declared.has(name)) {
        err(
          `${what}: not declared in module-fields.json — a manifest may only classify fields the schema defines`,
        );
      }
      if (apply === "composite") {
        if (!f.composite) {
          err(`${what}: apply:"composite" requires a 'composite' name`);
        } else if (!m.composites[f.composite]) {
          err(`${what}: names composite '${f.composite}', which this manifest does not declare`);
        }
        // The composite owns the side effects: it is the unit that is applied,
        // and the runner sequences ONE reboot/DNS pass per record. Letting an
        // input declare its own would mean two homes for the same fact.
        if ((f.sideEffects ?? []).length > 0) {
          err(`${what}: side effects belong on composite '${f.composite}', not on an input field`);
        }
      } else if (f.composite) {
        err(`${what}: declares composite '${f.composite}' but apply is '${apply}'`);
      }
      if (f.setFlag && apply !== "set") {
        err(`${what}: declares setFlag '${f.setFlag}' but apply is '${apply}'`);
      }
    }

    if (e.defaultIsDesired !== undefined && typeof e.defaultIsDesired !== "boolean") {
      err(`${what}: defaultIsDesired must be a boolean (got '${String(e.defaultIsDesired)}')`);
    }
    if (e.normalize !== undefined && !(NORMALIZERS as readonly string[]).includes(e.normalize)) {
      err(`${what}: unknown normalize '${e.normalize}' — must be one of: ${NORMALIZERS.join(" ")}`);
    }
    for (const s of e.sideEffects ?? []) {
      if (!(SIDE_EFFECTS as readonly string[]).includes(s)) {
        err(`${what}: unknown side effect '${s}' — must be one of: ${SIDE_EFFECTS.join(" ")}`);
      }
    }
    // A side effect on a non-disruptive class is a declaration mismatch: the
    // converge would perform a reboot the class says is never needed, so the
    // disruption gate (D8) would never be consulted for it.
    if (!spec.disruptive && (e.sideEffects ?? []).includes("reboot")) {
      err(`${what}: class '${e.class}' declares no disruption, but lists the 'reboot' side effect`);
    }
  }

  // COVERAGE — the rule ADR-020 P0 exists to add. Every field the schema says
  // this coordinate owns must be classified. Without it a provider can grow a
  // field whose change semantics nobody ever stated, which is precisely the
  // "hidden in an imperative loop" failure this ADR closes.
  const missing = opts.ownedFields.filter((f) => !m.fields[f]);
  if (missing.length > 0) {
    err(
      `fields.json does not classify ${missing.length} field(s) module-fields.json says '${opts.coordinate}' owns: ` +
        `${missing.join(", ")} — every usedBy field needs a change class (ADR-020 D4)`,
    );
  }
}

// Does a DEFAULTED (undeclared) value for this field participate in the
// converge? Reading it through one helper keeps the "absent means true" rule in
// one place, so a consumer cannot accidentally treat `undefined` as false.
export function defaultIsDesired(e: FieldEntry | CompositeEntry): boolean {
  return e.defaultIsDesired !== false;
}

// The fields module-fields.json says a coordinate owns: its `usedBy` set. Kept
// here (not in the caller) so validate, resolve and the converge all agree on
// what "owned" means.
export function ownedFieldsFor(
  coordinate: string,
  schema: Record<string, { usedBy?: string[] } | undefined>,
): string[] {
  const out: string[] = [];
  for (const [name, spec] of Object.entries(schema)) {
    const usedBy = Array.isArray(spec?.usedBy) ? spec!.usedBy! : [];
    if (usedBy.includes(coordinate)) out.push(name);
  }
  return out.sort();
}
