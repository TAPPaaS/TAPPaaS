// modify.test.ts — the `modify --set` static pre-gate (ADR-020 D2 step 0, P4).
//
// The scenario matrix M1–M9 the ADR specifies, as offline assertions against a
// temp config tree. What is under test is the GATE, not the converge: which
// changes may be written at all, and which must be refused before a single byte
// reaches the config.
//
// The line the gate draws is the one Resolved Question 4 draws. A refusal that
// needs LIVE state — is this disk grow a shrink? does this migrate need
// downtime? — cannot be made here and must not be attempted here; those refuse
// at apply time and the snapshot wrapper rolls back. A refusal that follows from
// the SCHEMA ALONE — immutable, recreate — must be made here, because writing it
// would leave config claiming something reality can never match, and every later
// reconcile would report drift nothing can fix.
//
// So M3 (a shrink) and M6 (a migrate needing downtime) are ACCEPTED by these
// tests. That is not an oversight; it is the decision.

import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { existsSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { parseSetArg, preGateSet } from "../../src/converge";
import { ModuleFieldsSchema } from "../../../../lib/ts/src/desired";
import { FakeModuleClient } from "./fake-client";
import { run } from "../../src/main";

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

// ── a temp estate: one module on cluster:vm, one provider with a manifest ──
const root = mkdtempSync(join(tmpdir(), "mm-modify-"));
const configDir = join(root, "config");
const clusterDir = join(root, "src", "cluster");
mkdirSync(configDir, { recursive: true });
mkdirSync(join(clusterDir, "services", "vm"), { recursive: true });

writeFileSync(
  join(configDir, "cluster.json"),
  JSON.stringify({ vmname: "cluster", location: clusterDir, kind: "module" }),
);
writeFileSync(
  join(configDir, "demo.json"),
  JSON.stringify({
    vmname: "demo",
    vmid: 300,
    kind: "module",
    dependsOn: ["cluster:vm"],
  }),
);
writeFileSync(
  join(clusterDir, "services", "vm", "fields.json"),
  JSON.stringify({
    service: "cluster:vm",
    fields: {
      cores: { class: "in-place", apply: "set" },
      diskSize: { class: "grow-only", apply: "hook", hook: "update-disk.sh" },
      zone0: { class: "in-place-reboot", apply: "composite", composite: "net0" },
      bridge0: { class: "in-place-reboot", apply: "composite", composite: "net0" },
      node: { class: "migrate", apply: "hook", hook: "update-node.sh" },
      storage: { class: "manual", apply: "none" },
      vmid: { class: "immutable", apply: "none" },
      bios: { class: "recreate", apply: "none" },
    },
    composites: {
      net0: {
        class: "in-place-reboot",
        apply: "hook",
        hook: "update-net.sh",
        inputs: ["zone0", "bridge0"],
      },
    },
  }),
);

// The verb path (`run(["modify", …])`) reads the schema from the config dir, as
// a deployed cicd does — module-fields.json there is a symlink to the repo
// schema. The fixture writes the same subset the tests inject directly, so the
// two paths agree.
const SCHEMA: ModuleFieldsSchema = {
  cores: { usedBy: ["cluster:vm"] },
  diskSize: { usedBy: ["cluster:vm"] },
  zone0: { usedBy: ["cluster:vm"] },
  node: { usedBy: ["cluster:vm"] },
  storage: { usedBy: ["cluster:vm"] },
  vmid: { usedBy: ["cluster:vm"] },
  bios: { usedBy: ["cluster:vm"] },
  description: { usedBy: ["general"] },
  dependsOn: {},
  proxyPort: { usedBy: ["network:proxy"] },
};

writeFileSync(join(configDir, "module-fields.json"), JSON.stringify({ fields: SCHEMA }));

const gate = (...pairs: string[]) =>
  preGateSet(configDir, "demo", pairs.map((p) => parseSetArg(p)!), SCHEMA);
const rejected = (r: ReturnType<typeof gate>, needle: string): boolean =>
  !r.ok && r.rejections.some((x) => x.reason.includes(needle));

try {
  // ── the scenarios the gate LETS THROUGH ──────────────────────────────
  {
    // M1 — an in-place change: a qm set, no downtime.
    const m1 = gate("cores=8");
    check(m1.ok, "M1 cores=8 (in-place) is accepted");
    check(m1.ok && m1.plan[0].class === "in-place", "…and the plan records the class it will converge as");

    // M2 — a grow. M3 — a SHRINK, which the gate must also accept: whether a
    // size change grows or shrinks is only knowable against the live disk, so
    // it is the converge that refuses, and the snapshot wrapper that rolls back.
    check(gate("diskSize=64G").ok, "M2 diskSize=64G (grow) is accepted");
    check(
      gate("diskSize=16G").ok,
      "M3 diskSize=16G (SHRINK) passes the gate — only the live size can tell, so the converge refuses it",
    );

    // M4 — a subnet change. Accepted here; the DISRUPTION it needs is
    // authorized (or deferred) at apply time by --force / rebootOk, not by
    // refusing the write.
    check(gate("zone0=iot").ok, "M4 zone0=iot (in-place-reboot) is accepted — downtime is the converge's question");

    // M5/M6 — a relocation, live-OK or not. Same reasoning as M3.
    const m5 = gate("node=tappaas3");
    check(m5.ok && m5.plan[0].class === "migrate", "M5/M6 node=tappaas3 (migrate) is accepted, classed migrate");

    // A `manual` field: reported and refused by the CONVERGE, but writing the
    // intent is useful, so it is not pre-gated.
    check(gate("storage=tankb1").ok, "storage=tankb1 (manual) is accepted — the converge reports it, an operator acts");

    // M8 — the plain #557 case: a policy-only field, no provider service, no
    // cluster change at all. This is what used to require hand-editing the
    // deployed config or a full reinstall.
    const m8 = gate("description=a new description");
    check(m8.ok, "M8 description=… (no provider owns it) is accepted");
    check(m8.ok && m8.plan[0].coordinate === "", "…and is marked config-only, since no converge will apply it");
    check(
      m8.ok && m8.plan[0].value === "a new description",
      "a value containing spaces survives parsing intact",
    );
  }

  // ── the scenarios the gate REFUSES ───────────────────────────────────
  {
    // M7 — immutable. The headline pre-gate case: config must never be left
    // ahead of a reality that can never catch up.
    const m7 = gate("vmid=250");
    check(!m7.ok, "M7 vmid=250 (immutable) is REJECTED before any write");
    check(rejected(m7, "delete"), "…and the message names the only way to change it: delete + reinstall");

    check(!gate("bios=seabios").ok, "bios=seabios (recreate) is REJECTED — it only takes effect at creation");

    // A field no declared service uses would be written and then ignored by
    // everything. Silence there is exactly the class of bug this ADR closes.
    const inert = gate("proxyPort=8443");
    check(!inert.ok, "a field none of the module's services use is REJECTED, not silently written");
    check(rejected(inert, "nothing else"), "…and says why: it would change the config and nothing else");

    const unknown = gate("nosuchfield=1");
    check(!unknown.ok, "a field the schema does not declare is REJECTED");
    check(rejected(unknown, "spelling"), "…and points at the likely cause");
  }

  // ── reject the WHOLE command (Resolved Question 5) ───────────────────
  {
    const mixed = gate("cores=8", "vmid=250");
    check(!mixed.ok, "a mixed --set with one immutable field is rejected");
    check(
      !mixed.ok && mixed.rejections.length === 1 && mixed.rejections[0].field === "vmid",
      "…naming only the field that is actually at fault",
    );
    // The point of reject-whole: `cores` must NOT be written. The gate returns
    // no plan at all, so the caller has nothing to write — config and cluster
    // move together or not at all.
    check(!mixed.ok && !("plan" in mixed), "…and yields NO plan, so nothing is written");
  }

  // ── parsing ──────────────────────────────────────────────────────────
  {
    check(parseSetArg("cores=8")?.value === "8", "field=value parses");
    check(
      parseSetArg("net0=virtio=02:AA,bridge=lan")?.value === "virtio=02:AA,bridge=lan",
      "only the FIRST '=' splits — a value may contain more",
    );
    check(parseSetArg("cores") === null, "a bare field with no '=' is not a set");
    check(parseSetArg("=8") === null, "an empty field name is not a set");
    check(parseSetArg("description=")?.value === "", "an empty VALUE is legal — clearing a field is a change");
  }

  // ── the verb wiring: gate, then write, then converge ─────────────────
  //
  // The seam the pre-gate tests above cannot reach: does `modify --set`
  // actually WRITE before it converges, and does a rejection stop BOTH? A gate
  // that rejects but still converges, or writes but never converges, would pass
  // every test above.
  {
    const setter = join(root, "fake-set-field.sh");
    const calls = join(root, "setter-calls");
    writeFileSync(setter, `#!/usr/bin/env bash\necho "$*" >> "${calls}"\nexit 0\n`);
    chmodSync(setter, 0o755);
    process.env.TAPPAAS_SET_FIELD_BIN = setter;

    const wrote = (): string => (existsSync(calls) ? readFileSync(calls, "utf8") : "");

    // Accepted: the writer runs, THEN the converge.
    {
      const client = new FakeModuleClient();
      const rc = run(["modify", "demo", "--set", "cores=8", "--config-dir", configDir], client);
      check(rc === 0, "an accepted --set exits 0");
      check(wrote().includes("demo --set cores=8"), "…the value is handed to the writer");
      check(
        client.log.some((i) => i.verb === "modify" && i.module === "demo"),
        "…and the ordinary modify algorithm runs afterwards — one verb, one algorithm",
      );
    }

    // Rejected: nothing is written and nothing converges.
    {
      rmSync(calls, { force: true });
      const client = new FakeModuleClient();
      const rc = run(["modify", "demo", "--set", "vmid=250", "--config-dir", configDir], client);
      check(rc !== 0, "a rejected --set exits non-zero");
      check(wrote() === "", "…the writer is never invoked");
      check(client.log.length === 0, "…and the converge never starts — the module is untouched");
    }

    // A mixed set stops the whole command, including the acceptable half.
    {
      rmSync(calls, { force: true });
      const client = new FakeModuleClient();
      run(["modify", "demo", "--set", "cores=8", "--set", "vmid=250", "--config-dir", configDir], client);
      check(wrote() === "", "a mixed --set writes NOTHING, not even the acceptable field");
      check(client.log.length === 0, "…and does not converge");
    }

    // --force is forwarded to the converge as disruption authorization (D8).
    {
      const client = new FakeModuleClient();
      run(["modify", "demo", "--force", "--config-dir", configDir], client);
      const inv = client.log.find((i) => i.verb === "modify");
      check(
        !!inv && (inv.opts as { force?: boolean }).force === true,
        "modify --force reaches the converge as the disruption authorization",
      );
    }

    delete process.env.TAPPAAS_SET_FIELD_BIN;
  }

  // A config dir with no schema at all: refuse, and say that is the reason.
  {
    const bare = mkdtempSync(join(tmpdir(), "mm-noschema-"));
    try {
      const r = preGateSet(bare, "demo", [parseSetArg("cores=8")!], {});
      check(!r.ok, "with no module-fields.json nothing is written");
      check(
        !r.ok && r.rejections[0].reason.includes("not readable"),
        "…and the reason is the missing schema, not a fabricated spelling complaint",
      );
    } finally {
      rmSync(bare, { recursive: true, force: true });
    }
  }

  // ── an un-migrated provider: warn, do not block ──────────────────────
  //
  // During the ADR-020 rollout most services have no manifest. The gate cannot
  // know their change classes, and refusing every --set until P5 finishes would
  // make the verb useless. It warns and lets the converge have the last word.
  {
    rmSync(join(clusterDir, "services", "vm", "fields.json"));
    const r = gate("cores=8");
    check(r.ok, "a provider with no manifest yet does not block a --set");
    check(
      r.warnings.some((w) => w.includes("no field manifest yet")),
      "…but the operator is told the change class is unknown",
    );
  }
} finally {
  rmSync(root, { recursive: true, force: true });
}

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
