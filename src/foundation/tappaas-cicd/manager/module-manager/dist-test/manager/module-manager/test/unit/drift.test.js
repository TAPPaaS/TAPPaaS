"use strict";
// drift.test.ts — offline unit tests for THE differ (ADR-020 D7, P2).
//
// Two kinds of assertion, and the second is the one that matters:
//
//   1. Each normalizer and each drift rule does what it says.
//   2. The REAL cluster:vm manifest, the REAL module-fields.json, and a report
//      shaped exactly as report-service.sh emits it produce ZERO drift for a
//      VM that is in sync. That is the whole contract end to end — resolver,
//      manifest, reporter and differ agreeing — and it is what would break if
//      any one of the four grew its own idea of a value again (#550).
//
// No cluster, no filesystem beyond reading the two committed JSON documents.
Object.defineProperty(exports, "__esModule", { value: true });
const fs_1 = require("fs");
const path_1 = require("path");
const drift_1 = require("../../../../lib/ts/src/drift");
const desired_1 = require("../../../../lib/ts/src/desired");
const service_fields_1 = require("../../../../lib/ts/src/service-fields");
let passed = 0;
let failed = 0;
function check(cond, msg) {
    if (cond) {
        passed++;
        console.log(`  ok: ${msg}`);
    }
    else {
        failed++;
        console.log(`  FAIL: ${msg}`);
    }
}
const FOUNDATION = (0, path_1.join)(__dirname, "..", "..", "..", "..", "..", "..", "..", "..");
const readJson = (p) => JSON.parse((0, fs_1.readFileSync)(p, "utf8"));
const SCHEMA = (readJson((0, path_1.join)(FOUNDATION, "schemas", "module-fields.json")).fields ??
    {});
const VM_MANIFEST = (() => {
    const f = [];
    const m = (0, service_fields_1.parseServiceFieldManifest)(readJson((0, path_1.join)(FOUNDATION, "cluster", "services", "vm", "fields.json")), f);
    if (!m)
        throw new Error("cluster:vm manifest did not parse");
    return m;
})();
// A zones.json with the shapes the normalizers must handle: a tagged service
// zone, the untagged management zone, an inactive one, and a Manual one (which
// is trunkable but not "active").
const ZONES = {
    rossen: { vlantag: 200, state: "Active" },
    mgmt: { vlantag: 0, state: "Manual" },
    iot: { vlantag: 410, state: "Active" },
    guest: { vlantag: 310, state: "Mandatory" },
    retired: { vlantag: 999, state: "Inactive" },
    _README: { note: "documentation block, never a zone" },
};
// ── 1. the normalizers: symmetric and idempotent ───────────────────────
{
    check((0, drift_1.normalizeValue)(" 8 ", "integer") === "8", "integer: whitespace and string/number spellings collapse");
    check((0, drift_1.normalizeValue)("08", "integer") === "8", "integer: a leading zero is the same number");
    check((0, drift_1.normalizeValue)("host", "integer") === "host", "integer: a non-number is passed through, not zeroed");
    check((0, drift_1.normalizeValue)("yes", "boolean") === "true" && (0, drift_1.normalizeValue)("0", "boolean") === "false", "boolean: the usual spellings collapse to true/false");
    check((0, drift_1.normalizeValue)("", "boolean") === "false", "boolean: absent is false");
    check((0, drift_1.normTags)("TAPPaaS,App") === "app;tappaas", "tags: lowercased, sorted, ';'-joined (how Proxmox stores them)");
    check((0, drift_1.normTags)("app;TAPPaaS;app") === "app;tappaas", "tags: duplicates collapse");
    check((0, drift_1.normTags)("a b") === "a;b", "tags: whitespace separates too (update-service.sh's rule)");
    check((0, drift_1.normTags)((0, drift_1.normTags)("TAPPaaS,App")) === (0, drift_1.normTags)("TAPPaaS,App"), "tags: idempotent");
    check((0, drift_1.normVlan)("rossen", ZONES) === "200", "vlan: a zone NAME resolves to its tag (the config spelling)");
    check((0, drift_1.normVlan)("200", ZONES) === "200", "vlan: a numeric tag is itself (the live spelling)");
    check((0, drift_1.normVlan)("", ZONES) === "0" && (0, drift_1.normVlan)("0", ZONES) === "0", "vlan: absent and explicit 0 are one value — untagged never reads as drift (#334)");
    check((0, drift_1.normVlan)("retired", ZONES) === "0", "vlan: an inactive zone yields no tag");
    check((0, drift_1.normVlan)("nosuchzone", ZONES) === "0", "vlan: an undefined zone yields no tag");
    // The point of symmetry: config says the name, the guest says the number.
    check((0, drift_1.normVlan)("rossen", ZONES) === (0, drift_1.normVlan)("200", ZONES), "vlan: the two spellings of one fact compare equal — this is what one normalizer buys");
    check((0, drift_1.normTrunks)("rossen;iot", ZONES) === "200;410", "trunks: zone names resolve to sorted tags");
    check((0, drift_1.normTrunks)("410;200", ZONES) === "200;410", "trunks: numeric tags are kept and sorted");
    check((0, drift_1.normTrunks)("NONE", ZONES) === "" && (0, drift_1.normTrunks)("", ZONES) === "", "trunks: NONE and empty are no trunks");
    check((0, drift_1.normTrunks)("ALL", ZONES) === "200;310;410", "trunks: the ALL sentinel expands to every active tag (#194)");
    check((0, drift_1.normTrunks)("mgmt", ZONES) === "", "trunks: an untagged zone contributes nothing");
    check((0, drift_1.normTrunks)("retired", ZONES) === "", "trunks: an inactive zone is not trunkable");
    check((0, drift_1.normTrunks)((0, drift_1.normTrunks)("rossen;iot", ZONES), ZONES) === "200;410", "trunks: idempotent");
    check((0, drift_1.normSize)("8G") === (0, drift_1.normSize)("8192M"), "size: one size, two spellings");
    check((0, drift_1.normSize)("80G") !== (0, drift_1.normSize)("8G"), "size: different sizes stay different");
    check((0, drift_1.normSize)("") === "", "size: empty stays empty, not zero bytes");
    check((0, drift_1.normSize)("nonsense") === "nonsense", "size: an unparseable value is passed through, not zeroed");
    check((0, drift_1.normalizeValue)("NONE", "optional") === "" && (0, drift_1.normalizeValue)("", "optional") === "", "optional: the NONE sentinel equals absent (bridge1: no second NIC)");
    check((0, drift_1.normalizeValue)("lan", "optional") === "lan", "optional: a real value is untouched");
}
// ── 2. the drift rules, on a small synthetic manifest ──────────────────
const SMALL = (0, service_fields_1.parseServiceFieldManifest)({
    service: "t:svc",
    fields: {
        cores: { class: "in-place", apply: "set", liveKey: "cores", normalize: "integer" },
        vmtag: { class: "in-place", apply: "set", liveKey: "tags", normalize: "tags" },
        vmid: { class: "immutable", apply: "none", liveKey: "vmid" },
        storage: { class: "manual", apply: "none", liveKey: "storage" },
        os: { class: "immutable", apply: "none" },
        bridge0: { class: "in-place-reboot", apply: "composite", composite: "net0", liveKey: "net0.bridge" },
        mac0: { class: "in-place", apply: "composite", composite: "net0", liveKey: "net0.mac" },
    },
    composites: {
        net0: {
            class: "in-place-reboot",
            apply: "hook",
            hook: "update-net.sh",
            liveKey: "net0",
            inputs: ["bridge0", "mac0"],
            sideEffects: ["reboot", "dns"],
        },
    },
}, []);
const SMALL_SCHEMA = {
    cores: { default: 2, usedBy: ["t:svc"] },
    vmtag: { default: "TAPPaaS", usedBy: ["t:svc"] },
    vmid: { usedBy: ["t:svc"] },
    storage: { default: "tanka1", usedBy: ["t:svc"] },
    os: { usedBy: ["t:svc"] },
    bridge0: { default: "lan", usedBy: ["t:svc"] },
    mac0: { default: "<randomly generated>", usedBy: ["t:svc"] },
};
function drift(cfg, actual) {
    const desired = (0, desired_1.resolveModule)("m", { dependsOn: ["t:svc"], ...cfg }, null, SMALL_SCHEMA);
    return (0, drift_1.computeDrift)(desired, { manifest: SMALL, actual, zones: ZONES });
}
const skipReason = (r, f) => r.skipped.find((s) => s.field === f)?.reason;
// In sync: every comparable field matches.
{
    const r = drift({ cores: 4, vmid: 300, storage: "tanka1", bridge0: "lan" }, { cores: "4", vmid: "300", storage: "tanka1", tags: "tappaas", "net0.bridge": "lan", "net0.mac": "02:AA" });
    check(!(0, drift_1.hasChanges)(r), "a VM matching its declared state has no drift");
    // vmtag is in this list although the module declares nothing: its schema
    // default is desired state, and the guest carries it because the creator
    // applied the same default (ADR-020 D9). Before D9 it was skipped instead.
    check(r.inSync.map((f) => f.field).sort().join() === "bridge0,cores,storage,vmid,vmtag", "the fields that were compared and matched are named");
}
// A plain in-place change becomes one `set` unit.
{
    const r = drift({ cores: 8, vmid: 300, bridge0: "lan" }, { cores: "4", vmid: "300", storage: "tanka1", tags: "tappaas", "net0.bridge": "lan", "net0.mac": "02:AA" });
    check(r.units.length === 1 && r.units[0].name === "cores", "a changed in-place field is one apply unit");
    check(r.units[0].apply === "set" && r.units[0].setFlag === "--cores", "…dispatched as a batched set with its flag");
    check(r.units[0].fields[0].desired === "8" && r.units[0].fields[0].actual === "4", "…carrying both raw values");
    check(!(0, drift_1.needsDisruption)(r), "an in-place change needs no disruption authorization");
}
// An immutable/manual change is reported and refused, never dispatched.
{
    const r = drift({ cores: 4, vmid: 999, storage: "tankb1", bridge0: "lan" }, { cores: "4", vmid: "300", storage: "tanka1", tags: "tappaas", "net0.bridge": "lan", "net0.mac": "02:AA" });
    check(r.units.length === 0, "a class the converge never applies produces no apply unit");
    check(r.unreconciled.map((f) => f.field).sort().join() === "storage,vmid", "…it is reported as unreconciled instead (immutable + manual)");
    check((0, drift_1.hasChanges)(r), "unreconciled drift still counts as drift — it is reported, not hidden");
}
// The skip reasons, each recorded rather than silently dropped. There used to be
// a third — "seed-only", for a field whose schema default was an install-time
// seed rather than desired state — retired with the flag behind it (ADR-020 D9).
{
    const r = drift({ cores: 4, vmid: 300, bridge0: "lan" }, { cores: "4", vmid: "300", "net0.bridge": "lan" });
    check(skipReason(r, "os") === "no-desired-value", "a field with neither a value nor an applicable default is skipped");
    check(skipReason(r, "mac0") === "no-desired-value", "a '<computed>' default is not desired state");
    check(skipReason(r, "storage") === "not-reported", "a field the reporter does not observe is skipped as such");
    check(r.skipped.every((s) => s.reason !== "seed-only"), "no field is skipped as an install-time seed — that reason no longer exists");
    check(r.skipped.length === 4, "every uncompared field is accounted for — none silently vanishes");
}
// An UNDECLARED field whose schema default is desired state is now COMPARED, not
// skipped. vmtag is the archetype: the default "TAPPaaS" is exactly what both
// create paths apply, so the guest already matches it and comparing is free.
{
    const r = drift({ cores: 4, vmid: 300, bridge0: "lan" }, { cores: "4", vmid: "300", tags: "tappaas", "net0.bridge": "lan", "net0.mac": "02:AA" });
    check(skipReason(r, "vmtag") === undefined, "an undeclared vmtag is compared against the schema default");
    check(r.inSync.some((f) => f.field === "vmtag" && f.defaulted), "…and matches the live 'tappaas', flagged as coming from the default");
}
// And it is still compared when the module DECLARES it.
{
    const r = drift({ cores: 4, vmid: 300, bridge0: "lan", vmtag: "TAPPaaS,App" }, { cores: "4", vmid: "300", storage: "tanka1", tags: "app;tappaas", "net0.bridge": "lan", "net0.mac": "02:AA" });
    check(skipReason(r, "vmtag") === undefined, "a declared vmtag is compared");
    check(!(0, drift_1.hasChanges)(r), "…and 'TAPPaaS,App' equals the live 'app;tappaas' after normalization");
}
// ── 3. composites: the effective class comes from what CHANGED ─────────
{
    // MAC only → in-place. No reboot, no DNS: exactly cluster:vm's behaviour.
    const macOnly = drift({ cores: 4, vmid: 300, bridge0: "lan", mac0: "02:BB" }, { cores: "4", vmid: "300", storage: "tanka1", tags: "tappaas", "net0.bridge": "lan", "net0.mac": "02:AA" });
    check(macOnly.units.length === 1 && macOnly.units[0].name === "net0", "a changed composite input produces ONE unit, the composite");
    check(macOnly.units[0].kind === "composite" && macOnly.units[0].hook === "update-net.sh", "…dispatched to the composite's hook");
    // Synthetic manifest: what is under test is the ESCALATION MECHANISM — an
    // input below the ceiling keeps the unit below it — not cluster:vm's own
    // classes. (Real cluster:vm classes mac0 as in-place-reboot; its `trunks0`
    // is the field that actually stays in-place, being bridge-side.)
    check(macOnly.units[0].class === "in-place", "an input below the ceiling keeps the unit below the ceiling");
    check(macOnly.units[0].sideEffects.length === 0, "…so a non-disruptive effective class earns no side effects");
    check(!(0, drift_1.needsDisruption)(macOnly), "…and it needs no disruption authorization");
    // Bridge → in-place-reboot, and NOW the side effects apply.
    const bridgeChange = drift({ cores: 4, vmid: 300, bridge0: "iotbr", mac0: "02:AA" }, { cores: "4", vmid: "300", storage: "tanka1", tags: "tappaas", "net0.bridge": "lan", "net0.mac": "02:AA" });
    check(bridgeChange.units[0].class === "in-place-reboot", "a bridge change escalates the composite to in-place-reboot");
    check(bridgeChange.units[0].sideEffects.join() === "reboot,dns", "…and earns the declared reboot + DNS pass");
    check((0, drift_1.needsDisruption)(bridgeChange), "…and needs disruption authorization (D8)");
    // Both inputs changed: still ONE unit, escalated, with the effects once.
    const both = drift({ cores: 4, vmid: 300, bridge0: "iotbr", mac0: "02:BB" }, { cores: "4", vmid: "300", storage: "tanka1", tags: "tappaas", "net0.bridge": "lan", "net0.mac": "02:AA" });
    check(both.units.length === 1 && both.units[0].fields.length === 2, "two changed inputs are one composite unit carrying both");
    check((0, drift_1.unitSideEffects)(both).join() === "reboot,dns", "the side effects are sequenced ONCE across the record, never once per changed field");
}
// Determinism: the record must not depend on object iteration order.
{
    const a = drift({ cores: 8, vmid: 300, bridge0: "iotbr" }, { cores: "4", vmid: "300", storage: "tanka1", tags: "tappaas", "net0.bridge": "lan", "net0.mac": "02:AA" });
    const b = drift({ bridge0: "iotbr", vmid: 300, cores: 8 }, { "net0.mac": "02:AA", tags: "tappaas", storage: "tanka1", vmid: "300", cores: "4", "net0.bridge": "lan" });
    check(JSON.stringify(a.units.map((u) => u.name)) === JSON.stringify(b.units.map((u) => u.name)), "unit order follows the manifest, not the input's key order — the record is reproducible");
}
// ── 4. the real thing: cluster:vm, in sync, zero drift ─────────────────
//
// The desired side is a real deployed nextcloud config; the actual side is
// exactly the object report-service.sh emits for it. If the resolver, the
// manifest, the reporter and the differ agree, this is empty.
{
    const cfg = {
        vmname: "nextcloud",
        vmid: 340,
        node: "tappaas1",
        vmtag: "TAPPaaS,App",
        bios: "ovmf",
        ostype: "l26",
        cputype: "host",
        cores: 4,
        memory: 8192,
        diskSize: "80G",
        storage: "tanka1",
        zone0: "rossen",
        bridge0: "lan",
        imageType: "clone",
        image: "8080",
        os: "nixos",
        cloudInit: "true",
        dependsOn: ["cluster:vm", "templates:nixos", "network:proxy"],
    };
    const actual = {
        vmid: "340",
        node: "tappaas1",
        status: "running",
        name: "nextcloud",
        cores: "4",
        memory: "8192",
        cpu: "host",
        tags: "app;tappaas",
        bios: "ovmf",
        ostype: "l26",
        storage: "tanka1",
        diskSize: "80G",
        net0: "virtio=02:C8:41:33:F4:0D,bridge=lan,tag=200",
        "net0.bridge": "lan",
        "net0.tag": "200",
        "net0.trunks": "",
        "net0.mac": "02:C8:41:33:F4:0D",
        "net0.queues": "",
        net1: "",
        "net1.bridge": "",
        "net1.tag": "",
        "net1.trunks": "",
        "net1.mac": "",
        "net1.queues": "",
    };
    const desired = (0, desired_1.resolveModule)("nextcloud", cfg, null, SCHEMA);
    const r = (0, drift_1.computeDrift)(desired, { manifest: VM_MANIFEST, actual, zones: ZONES });
    const describe = (d) => [...d.units.flatMap((u) => u.fields), ...d.unreconciled]
        .map((f) => `${f.field}: '${f.desiredNorm}' != '${f.actualNorm}'`)
        .join(" | ");
    check(!(0, drift_1.hasChanges)(r), `an in-sync nextcloud reports NO drift${(0, drift_1.hasChanges)(r) ? " — " + describe(r) : ""}`);
    // The two that used to be false drift, asserted by name so a regression is
    // legible rather than just "something drifted".
    check(r.inSync.some((f) => f.field === "bridge1") || r.skipped.some((s) => s.field === "bridge1"), "bridge1 is not drift on a one-NIC VM (its default is the NONE sentinel)");
    check(r.inSync.some((f) => f.field === "zone0" && f.desired === "rossen" && f.actual === "200"), "zone0 compares the config's zone NAME against the guest's VLAN TAG and agrees");
    // And a real change is detected, with the right class and authorization.
    const moved = (0, drift_1.computeDrift)((0, desired_1.resolveModule)("nextcloud", { ...cfg, node: "tappaas3" }, null, SCHEMA), { manifest: VM_MANIFEST, actual, zones: ZONES });
    check(moved.units.length === 1 && moved.units[0].name === "node" && moved.units[0].class === "migrate", "a node change is one migrate unit");
    check(moved.units[0].hook === "update-node.sh", "…dispatched to the ADR-019 bridge hook");
    check((0, drift_1.needsDisruption)(moved), "…and needs disruption authorization until live-OK says otherwise");
    const grown = (0, drift_1.computeDrift)((0, desired_1.resolveModule)("nextcloud", { ...cfg, diskSize: "120G" }, null, SCHEMA), { manifest: VM_MANIFEST, actual, zones: ZONES });
    check(grown.units.length === 1 && grown.units[0].class === "grow-only" && !(0, drift_1.needsDisruption)(grown), "a disk grow is one grow-only unit and needs no downtime");
    // ── the other direction: config BEHIND a completed grow (ADR-020 D9) ──
    //
    // The guest is bigger than config asks for, because something grew it outside
    // the config path. Applying that is a shrink, which update-disk.sh refuses
    // (exit 20) — and used to refuse identically on every future pass, with no way
    // out. It is now an ADOPTION: config moves forward, the cluster is untouched.
    const lagging = (0, drift_1.computeDrift)((0, desired_1.resolveModule)("nextcloud", { ...cfg, diskSize: "40G" }, null, SCHEMA), { manifest: VM_MANIFEST, actual, zones: ZONES });
    check(lagging.adopt.length === 1 && lagging.adopt[0].field === "diskSize", "config behind a grown disk is recorded as an adoption");
    check(lagging.adopt[0].actual === "80G" && lagging.adopt[0].desired === "40G", "…carrying the observed size to write into config");
    check(lagging.units.length === 0 && lagging.unreconciled.length === 0, "…and is NOT dispatched as an apply, nor reported as unreconcilable");
    check((0, drift_1.hasChanges)(lagging), "…but still counts as a change, so --check reports it");
    // A shrink is only an adoption when actual genuinely EXCEEDS desired. Equal
    // sizes spelled differently must stay in sync, not adopt: 80G vs 81920M is
    // the same disk, and the size normalizer is what makes that true.
    const sameSize = (0, drift_1.computeDrift)((0, desired_1.resolveModule)("nextcloud", { ...cfg, diskSize: "81920M" }, null, SCHEMA), { manifest: VM_MANIFEST, actual, zones: ZONES });
    check(sameSize.adopt.length === 0 && sameSize.units.length === 0, "80G and 81920M are the same disk — neither an apply nor an adoption");
}
console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
