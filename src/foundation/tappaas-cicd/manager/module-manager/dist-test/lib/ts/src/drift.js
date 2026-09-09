"use strict";
// drift.ts — THE differ (ADR-020 D7).
//
// One drift computation, in the manager, shared by every path that needs to
// know how a module's live state differs from its declared state:
//
//     desired = module resolve <name>              [desired.ts — the one resolver]
//     actual  = <svc>/report-service.sh <name>     [bash — extract only]
//     drift   = computeDrift(desired, actual, …)   [HERE — the one differ]
//               <svc>/update-service.sh --apply-drift <file>   [bash — apply only]
//
// Services never compute drift and never normalize. They report raw values and
// apply the record they are handed. That is what makes "the reported drift and
// the applied drift are the same drift" true by construction rather than by
// two code paths happening to agree — which they did not: `inspect.ts` and
// `cluster:vm/update-service.sh` each had their own normalization, their own
// idea of which fields to compare, and their own defaults (#550).
//
// PURE. Parsed documents in, a drift record out. No filesystem, no cluster, no
// manager imports — so every rule below is unit-testable offline, and
// `network-manager` gets the same differ (ADR-020 D6/Q7).
Object.defineProperty(exports, "__esModule", { value: true });
exports.allActiveTags = allActiveTags;
exports.normTags = normTags;
exports.normVlan = normVlan;
exports.normTrunks = normTrunks;
exports.normSize = normSize;
exports.normOptional = normOptional;
exports.normalizeValue = normalizeValue;
exports.hasChanges = hasChanges;
exports.needsDisruption = needsDisruption;
exports.unitSideEffects = unitSideEffects;
exports.computeDrift = computeDrift;
const service_fields_1 = require("./service-fields");
function zoneEntry(zones, zone) {
    if (!zones || !(zone in zones))
        return null;
    const z = zones[zone];
    return z !== null && typeof z === "object" && !Array.isArray(z) ? z : {};
}
function zoneTag(entry) {
    const t = entry.vlantag;
    return typeof t === "number" ? t : 0; // jq `.vlantag // 0`
}
function zoneState(entry) {
    const s = entry.state;
    return typeof s === "string" ? s : "";
}
// Every Active/Mandatory zone's non-zero tag, sorted — the "ALL" trunk sentinel
// (vmnet_all_active_tags, #194), which lets the firewall VM auto-trunk a new
// zone without editing its config.
function allActiveTags(zones) {
    if (!zones)
        return [];
    const tags = [];
    for (const v of Object.values(zones)) {
        if (v === null || typeof v !== "object" || Array.isArray(v))
            continue;
        const entry = v;
        const state = zoneState(entry);
        if (state !== "Active" && state !== "Mandatory")
            continue;
        const tag = zoneTag(entry);
        if (tag > 0)
            tags.push(tag);
    }
    return [...new Set(tags)].sort((a, b) => a - b);
}
// ── the normalizers ────────────────────────────────────────────────────
//
// Every normalizer is SYMMETRIC and IDEMPOTENT: it is applied to the desired
// and the actual value alike, and normalizing an already-normalized value
// changes nothing. That is a stronger contract than the ad-hoc helpers it
// replaces — inspect.ts resolved trunk ZONE NAMES on the config side and merely
// sorted VLAN IDS on the live side, two different functions for one comparison.
// Here one function handles both, because a token that is already a number is
// simply kept.
const NONE_SENTINELS = new Set(["none", "null", "-"]);
function normInteger(v) {
    const n = Number(v.trim());
    return Number.isFinite(n) ? String(n) : v.trim();
}
const TRUE_WORDS = new Set(["true", "yes", "on", "1"]);
const FALSE_WORDS = new Set(["false", "no", "off", "0", ""]);
function normBoolean(v) {
    const s = v.trim().toLowerCase();
    if (TRUE_WORDS.has(s))
        return "true";
    if (FALSE_WORDS.has(s))
        return "false";
    return s;
}
// Proxmox stores tags lowercased, de-duplicated and ';'-joined; module JSON may
// use mixed case, commas or spaces. Both sides collapse to that canonical form.
// (update-service.sh's normalize_tags deduped and split on whitespace too;
// inspect.ts's did neither — the union is correct for both.)
function normTags(v) {
    const parts = v
        .split(/[,;\s]+/)
        .map((x) => x.trim().toLowerCase())
        .filter((x) => x !== "");
    return [...new Set(parts)].sort().join(";");
}
// A VLAN tag. Accepts either spelling of the same fact: a zone NAME (what
// config declares) or a numeric tag (what the guest reports). Untagged is "0",
// so an absent tag and an explicit 0 never read as drift (#334).
function normVlan(v, zones) {
    const s = v.trim();
    if (s === "" || NONE_SENTINELS.has(s.toLowerCase()))
        return "0";
    if (/^\d+$/.test(s))
        return String(Number(s));
    const entry = zoneEntry(zones, s);
    // An undefined or inactive zone yields no tag. The bash returned rc 1 here and
    // inspect-vm.sh's `|| true` collapsed it to "" → rendered "(untagged)"; "0" is
    // that same value in canonical form.
    if (!entry || zoneState(entry) === "Inactive")
        return "0";
    return String(zoneTag(entry));
}
// A trunk allow-list, as VLAN tags, sorted numerically. Accepts zone names (the
// config spelling), numeric tags (the live spelling), the "ALL"/"*" sentinel,
// and "NONE"/empty for no trunks. Non-trunkable (not Active/Mandatory/Manual)
// and untagged zones are dropped, as vmnet_resolve_trunks does.
function normTrunks(v, zones) {
    const s = v.trim();
    if (s === "" || NONE_SENTINELS.has(s.toLowerCase()))
        return "";
    if (s === "ALL" || s === "*")
        return allActiveTags(zones).join(";");
    const tags = [];
    for (const raw of s.split(/[;,]/)) {
        const name = raw.trim();
        if (name === "")
            continue;
        if (/^\d+$/.test(name)) {
            const n = Number(name);
            if (n > 0)
                tags.push(n);
            continue;
        }
        const entry = zoneEntry(zones, name);
        if (!entry)
            continue; // undefined trunk zone — nothing to compare against
        const state = zoneState(entry);
        if (state !== "Active" && state !== "Mandatory" && state !== "Manual")
            continue;
        const tag = zoneTag(entry);
        if (tag > 0)
            tags.push(tag);
    }
    return [...new Set(tags)].sort((a, b) => a - b).join(";");
}
const SIZE_UNITS = {
    "": 1,
    b: 1,
    k: 1024,
    m: 1024 ** 2,
    g: 1024 ** 3,
    t: 1024 ** 4,
    p: 1024 ** 5,
};
// A size with a unit suffix, as bytes, so "8G" and "8192M" are one value. A
// value that is not a size at all is passed through trimmed rather than
// silently becoming 0 — an unparseable size must read as different from a
// parseable one, not as zero bytes.
function normSize(v) {
    const m = /^\s*([0-9]+(?:\.[0-9]+)?)\s*([bkmgtpBKMGTP]?)i?[bB]?\s*$/.exec(v);
    if (!m)
        return v.trim();
    const mult = SIZE_UNITS[m[2].toLowerCase()] ?? 1;
    return String(Math.round(Number(m[1]) * mult));
}
// "NONE" is the TAPPaaS-wide sentinel for "not set" — bridge1 uses it to mean
// the guest has no second NIC. Collapsing it to empty is what lets an
// undeclared optional component compare equal to a component the guest does
// not have, instead of drifting forever against the string "NONE".
function normOptional(v) {
    const s = v.trim();
    return NONE_SENTINELS.has(s.toLowerCase()) ? "" : s;
}
function normalizeValue(value, normalizer, ctx = {}) {
    const zones = ctx.zones ?? null;
    switch (normalizer) {
        case "integer":
            return normInteger(value);
        case "boolean":
            return normBoolean(value);
        case "tags":
            return normTags(value);
        case "vlan":
            return normVlan(value, zones);
        case "trunks":
            return normTrunks(value, zones);
        case "size":
            return normSize(value);
        case "optional":
            return normOptional(value);
        case "string":
        default:
            return value.trim();
    }
}
function hasChanges(r) {
    return r.units.length > 0 || r.unreconciled.length > 0 || r.adopt.length > 0;
}
// True when applying this record needs disruption authorization (ADR-020 D8):
// `modify --force`, or rebootOk in the scheduled pass.
function needsDisruption(r) {
    return r.units.some((u) => service_fields_1.CHANGE_CLASSES[u.class]?.disruptive === true);
}
// The union of every unit's side effects, in declaration order, deduplicated —
// so two changed NICs still produce exactly ONE reboot and ONE DNS pass, which
// is the ordering cluster:vm hand-rolls today.
function unitSideEffects(r) {
    const seen = new Set();
    const out = [];
    for (const u of r.units) {
        for (const s of u.sideEffects) {
            if (!seen.has(s)) {
                seen.add(s);
                out.push(s);
            }
        }
    }
    return out;
}
function entryLiveKey(field, e) {
    return e.liveKey ?? field;
}
// The composite's side effects apply only when the change actually escalated to
// a disruptive class. A MAC- or trunk-only NIC change is applied live with no
// reboot and no DNS pass, exactly as today; only a bridge/zone change — which
// moves the guest to a different subnet — earns them. If a service ever needs a
// side effect on a non-disruptive change, that wants its own declaration rather
// than widening this rule.
function unitSideEffectsFor(entry, effClass) {
    const declared = entry.sideEffects ?? [];
    if (declared.length === 0)
        return [];
    return service_fields_1.CHANGE_CLASSES[effClass]?.disruptive ? [...declared] : [];
}
function computeDrift(desired, opts) {
    const { manifest, actual } = opts;
    const record = {
        module: desired.module,
        service: manifest.service,
        actual: { ...actual },
        units: [],
        unreconciled: [],
        adopt: [],
        inSync: [],
        skipped: [],
    };
    // Changed fields, grouped by the unit that will apply them.
    const changedByUnit = new Map();
    for (const [field, entry] of Object.entries(manifest.fields)) {
        const resolved = desired.fields[field];
        if (!resolved) {
            record.skipped.push({ field, reason: "no-desired-value" });
            continue;
        }
        // The schema default is an install-time seed for this (field, service), not
        // desired state — cluster:vm's `__none__` sentinel, declared. The module
        // never asked for this value, so the converge must not act on it.
        // The service converges this field inside its own idempotent reconcile
        // (apply:"reconcile"). There is nothing for the generic differ to compare —
        // a firewall rule set is not a scalar — and the comparison that matters is
        // the domain-aware one its test-service.sh already performs. Recorded, so
        // the report says WHY it was not diffed rather than staying silent.
        if ((0, service_fields_1.effectiveApply)(entry) === "reconcile") {
            record.skipped.push({ field, reason: "self-reconciling" });
            continue;
        }
        const liveKey = entryLiveKey(field, entry);
        if (!(liveKey in actual)) {
            record.skipped.push({ field, reason: "not-reported" });
            continue;
        }
        const rawActual = actual[liveKey];
        const desiredNorm = normalizeValue(resolved.value, entry.normalize, opts);
        const actualNorm = normalizeValue(rawActual, entry.normalize, opts);
        const df = {
            field,
            class: entry.class,
            liveKey,
            desired: resolved.value,
            actual: rawActual,
            desiredNorm,
            actualNorm,
            defaulted: resolved.defaulted,
            composite: entry.composite,
        };
        if (desiredNorm === actualNorm) {
            record.inSync.push(df);
            continue;
        }
        // Changed, and the change is BACKWARDS for a grow-only field: the guest is
        // already bigger than config asks for. Never an apply — that direction is
        // refused — and not a failure either, because config lagging a completed
        // grow is an accounting gap, not a fault. Recorded as an adoption so the
        // converge can close it instead of failing on it forever.
        if (entry.class === "grow-only") {
            const d = Number(desiredNorm);
            const a = Number(actualNorm);
            if (Number.isFinite(d) && Number.isFinite(a) && a > d) {
                record.adopt.push(df);
                continue;
            }
        }
        // Changed. A class the converge never applies is reported and refused, not
        // dispatched — the caller decides whether that is fatal (a `--set` on it is
        // rejected by the static pre-gate long before here) or merely a warning.
        if (!service_fields_1.CHANGE_CLASSES[entry.class]?.applies) {
            record.unreconciled.push(df);
            continue;
        }
        const unitName = entry.composite ?? field;
        const list = changedByUnit.get(unitName);
        if (list)
            list.push(df);
        else
            changedByUnit.set(unitName, [df]);
    }
    // Turn each group of changed fields into an apply unit. Iterate the MANIFEST
    // order, not the map's, so the record is deterministic for a given manifest —
    // a drift record that reorders between runs is unusable in a diff or a test.
    const unitOrder = [...Object.keys(manifest.fields), ...Object.keys(manifest.composites)];
    const emitted = new Set();
    for (const name of unitOrder) {
        const fields = changedByUnit.get(name);
        if (!fields || emitted.has(name))
            continue;
        emitted.add(name);
        const composite = manifest.composites[name];
        const entry = composite ?? manifest.fields[name];
        if (!entry)
            continue;
        const effClass = (0, service_fields_1.worstClass)(fields.map((f) => f.class)) ?? entry.class;
        record.units.push({
            name,
            kind: composite ? "composite" : "field",
            class: effClass,
            disruptive: service_fields_1.CHANGE_CLASSES[effClass]?.disruptive === true,
            apply: (0, service_fields_1.effectiveApply)(entry),
            hook: entry.hook,
            liveKey: entry.liveKey ?? (composite ? name : name),
            setFlag: entry.setFlag ?? (composite ? undefined : `--${entryLiveKey(name, entry)}`),
            sideEffects: unitSideEffectsFor(entry, effClass),
            fields,
        });
    }
    return record;
}
