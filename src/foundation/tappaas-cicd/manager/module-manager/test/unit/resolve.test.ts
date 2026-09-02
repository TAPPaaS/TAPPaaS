// resolve.test.ts — offline unit tests for THE desired-state resolver
// (ADR-020 D1, P1) and the `module resolve` verb built on it.
//
// The property under test is not "the resolver is correct" but "there is only
// ONE of it". #550 was two resolvers disagreeing: inspect rendered an
// undeclared cputype as "-" while the update path defaulted it to 'host'. So
// the decisive assertions here are the SHARED-SOURCE ones — the same input
// resolved through `buildVmReport` (the reporting path) and through
// `resolveModule` (the acting path's input) must produce the same value, for
// the same reason, from the same code.
//
// That is the mutation test the ADR asks for, expressed structurally: both
// paths import from lib/ts/src/desired.ts, and the agreement cases below fail
// the moment anyone reintroduces a private default ladder in either one.
//
// Offline: parsed documents in, values out. No cluster, no config tree except
// a small temp fixture for the verb.

import { mkdtempSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  ModuleFieldsSchema,
  appliedDefault,
  getField,
  jqStr,
  resolveField,
  resolveModule,
} from "../../../../lib/ts/src/desired";
import { buildVmReport } from "../../src/inspect";
import { renderResolved, resolveModuleFromConfig } from "../../src/resolve";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) {
    passed++;
    console.log(`  ok: ${msg}`);
  } else {
    failed++;
    console.log(`  FAIL: ${msg}`);
  }
}

// A miniature module-fields.json: one general field, one gated on cluster:vm,
// one gated on network:proxy, one "<computed>" placeholder, one non-scalar.
const SCHEMA: ModuleFieldsSchema = {
  status: { default: "Development", usedBy: ["general"] },
  cputype: { default: "host", usedBy: ["cluster:vm"] },
  cores: { default: 2, usedBy: ["cluster:vm", "cluster:lxc"] },
  proxyPort: { default: 8080, usedBy: ["network:proxy"] },
  mac0: { default: "<randomly generated>", usedBy: ["cluster:vm"] },
  backup: { default: {}, usedBy: ["backup:vm"] },
  ungated: { default: "yes" },
};

// ── 1. jq parity — the semantics the bash readers had ──────────────────
{
  check(jqStr(undefined) === "" && jqStr(null) === "" && jqStr(false) === "", "missing/null/false resolve to empty");
  check(jqStr(0) === "0", "zero is a value, not emptiness");
  check(jqStr(true) === "true", "true renders as its string form");
  check(jqStr(["a", "b"]) === '["a","b"]', "a container renders as JSON");
  check(getField(null, "x") === "", "reading a field off a missing document is empty, not a throw");
}

// ── 2. appliedDefault — the usedBy gate ────────────────────────────────
{
  const vm = ["cluster:vm"];
  check(appliedDefault("cputype", vm, SCHEMA) === "host", "a cluster:vm default applies to a cluster:vm module");
  check(
    appliedDefault("proxyPort", vm, SCHEMA) === "",
    "a network:proxy default does NOT apply to a module without network:proxy",
  );
  check(
    appliedDefault("proxyPort", ["network:proxy"], SCHEMA) === "8080",
    "the same default DOES apply once the module declares the provider",
  );
  check(appliedDefault("status", [], SCHEMA) === "Development", "a 'general' default applies to every module");
  check(appliedDefault("ungated", [], SCHEMA) === "yes", "a default with no usedBy applies to every module");
  check(
    appliedDefault("mac0", vm, SCHEMA) === "",
    "a '<computed>' placeholder is not a default — an install-time value is not desired state",
  );
  check(appliedDefault("backup", ["backup:vm"], SCHEMA) === "", "a non-scalar default is not resolved to a value");
  check(appliedDefault("nosuchfield", vm, SCHEMA) === "", "a field the schema does not declare has no default");
}

// ── 3. resolveField — literal wins, default fills in ───────────────────
{
  const cfg = { cputype: "kvm64", cores: 8 };
  const vm = ["cluster:vm"];
  const a = resolveField(cfg, "cputype", vm, SCHEMA);
  check(a.value === "kvm64" && !a.defaulted, "a declared value wins over the schema default");
  const b = resolveField(cfg, "status", vm, SCHEMA);
  check(b.value === "Development" && b.defaulted, "an undeclared field resolves to its default, marked as defaulted");
  const c = resolveField(cfg, "proxyPort", vm, SCHEMA);
  check(c.value === "" && !c.defaulted, "an out-of-scope field resolves to nothing at all");
}

// ── 4. resolveModule — the document ────────────────────────────────────
{
  const cfg = {
    vmname: "app",
    cputype: "kvm64",
    dependsOn: ["cluster:vm"],
    integratesWith: ["vllm-amd:inference"],
  };
  const orig = { vmname: "app", cputype: "host", dependsOn: ["cluster:vm"] };
  const r = resolveModule("app", cfg, orig, SCHEMA);

  check(r.fields.cputype.value === "kvm64", "a declared field carries its literal value");
  check(r.fields.cputype.literal === "kvm64", "…and reports it as the literal");
  check(r.fields.cores.value === "2" && r.fields.cores.defaulted, "an undeclared in-scope field is defaulted in");
  check(
    r.fields.cores.literal === "",
    "a defaulted field's literal is empty — 'declared as the default' and 'not declared' stay distinguishable",
  );
  check(r.fields.proxyPort === undefined, "an out-of-scope field is absent from the document, not present-and-empty");
  check(r.fields.cputype.notTracking, "a field differing from .orig is flagged as deliberately off release");
  check(!r.fields.vmname.notTracking, "a field matching .orig is not flagged");
  check(r.origAvailable, "the document says a .orig pre-image was available");
  check(
    r.dependsOn.join() === "cluster:vm" && r.integratesWith.join() === "vllm-amd:inference",
    "the document records the coordinates that scoped the defaults",
  );
  // The gate is dependsOn, not integratesWith: an optional integration may have
  // no provider installed, so defaulting its fields in would invent state.
  check(
    resolveModule("app", { dependsOn: [], integratesWith: ["network:proxy"] }, null, SCHEMA).fields.proxyPort ===
      undefined,
    "an integratesWith coordinate does not pull in that service's defaults",
  );

  const noOrig = resolveModule("app", cfg, null, SCHEMA);
  check(
    !noOrig.origAvailable && !noOrig.fields.cputype.notTracking,
    "with no .orig, nothing is flagged and the document SAYS the pre-image was missing",
  );
}

// ── 5. THE SHARED-SOURCE ASSERTION (the point of P1) ───────────────────
//
// Resolve one module two ways — through the report builder and through the
// resolver document — and require identical values. These fail if either path
// ever grows its own defaulting again, which is precisely #550.
{
  const cfg = {
    vmname: "app",
    vmid: 300,
    node: "tappaas1",
    dependsOn: ["cluster:vm"],
    // cputype and cores are DELIBERATELY undeclared: the whole disagreement in
    // #550 was about a field nobody declared.
  };
  const report = buildVmReport({
    module: "app",
    vmid: "300",
    cfg,
    git: null,
    zones: null,
    actual: { name: "app", cores: "2", cpu: "host" },
    vmStatus: "running",
    actualNode: "tappaas1",
    schema: SCHEMA,
    orig: null,
  });
  const resolved = resolveModule("app", cfg, null, SCHEMA);
  const reportText = report.lines.map((l) => l.text).join("\n");

  check(
    resolved.fields.cputype.value === "host" && resolved.fields.cputype.defaulted,
    "the resolver defaults an undeclared cputype to 'host' (#550)",
  );
  // The report marks a defaulted value with <angle brackets>; the value inside
  // must be the resolver's, character for character.
  check(
    reportText.includes("<host>"),
    "the inspect report shows the SAME defaulted cputype the resolver produced",
  );
  check(
    reportText.includes("<2>"),
    "the inspect report shows the SAME defaulted cores the resolver produced",
  );
  // And the negative: a field out of scope must be absent from BOTH.
  check(
    resolved.fields.proxyPort === undefined && !reportText.includes("8080"),
    "an out-of-scope default appears in neither path",
  );
  check(
    report.errors === 0,
    "a VM matching its resolved desired state reports no drift — the two agree on 'in sync' too",
  );
}

// ── 6. the verb: reading a real (temp) config tree ─────────────────────
{
  const dir = mkdtempSync(join(tmpdir(), "mm-resolve-"));
  try {
    writeFileSync(
      join(dir, "module-fields.json"),
      JSON.stringify({ fields: { cputype: { default: "host", usedBy: ["cluster:vm"] } } }),
    );
    writeFileSync(
      join(dir, "app.json"),
      JSON.stringify({ vmname: "app", environment: "prod", dependsOn: ["cluster:vm"] }),
    );
    writeFileSync(join(dir, "app.json.orig"), JSON.stringify({ vmname: "app", environment: "dev" }));

    const r = resolveModuleFromConfig("app", dir);
    check(r !== null, "the verb resolves a deployed module");
    check(r!.fields.cputype.value === "host" && r!.fields.cputype.defaulted, "the verb fills in schema defaults");
    check(r!.fields.environment.notTracking, "the verb flags a field deliberately off its release");
    check(resolveModuleFromConfig("nosuch", dir) === null, "an undeployed module resolves to null (rc 1 at the verb)");

    // Pattern-A config blocks must be flattened before resolution, or a field
    // nested under a provider block would look undeclared and get defaulted.
    writeFileSync(
      join(dir, "b.json"),
      JSON.stringify({ vmname: "b", dependsOn: ["cluster:vm"], config: { "cluster:vm": { cputype: "kvm64" } } }),
    );
    const rb = resolveModuleFromConfig("b", dir);
    check(
      rb!.fields.cputype.value === "kvm64" && !rb!.fields.cputype.defaulted,
      "a Pattern-A config block is flattened before resolving (not defaulted over)",
    );

    // Rendering: a long container value is truncated VISIBLY, never silently.
    const long = "x".repeat(200);
    const text = renderResolved({
      module: "m",
      dependsOn: [],
      integratesWith: [],
      origAvailable: true,
      fields: { big: { value: long, defaulted: false, literal: long, notTracking: false } },
    }).join("\n");
    check(
      text.includes("…") && text.includes("200 chars, see --json") && !text.includes(long),
      "a long value is truncated in the human table and says so",
    );
    const noOrigText = renderResolved({
      module: "m",
      dependsOn: [],
      integratesWith: [],
      origAvailable: false,
      fields: {},
    }).join("\n");
    check(
      noOrigText.includes("no <module>.json.orig"),
      "a missing pre-image is stated, not left to read as 'nothing is off release'",
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
