// stack.test.ts — add-stack's plan (#763): order, cycles, skips, missing
// outside dependencies, hand steps; and that the order is the one each stack's
// generated INSTALL.md shows.

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { StackModule, hasHandSteps, installOrder, planStack } from "../../src/stack";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) { passed++; console.log(`  ✓ ${msg}`); }
  else { failed++; console.log(`  ✗ ${msg}`); }
}

const mod = (name: string, dependsOn: string[] = [], integratesWith: string[] = [], handSteps = false): StackModule =>
  ({ name, dependsOn, integratesWith, handSteps });

// The collaboration stack's shape.
const collab = [
  mod("nextcloud-hpb", ["cluster:vm", "coturn:turn", "nextcloud:fileservice"]),
  mod("euro-office", ["cluster:vm", "nextcloud:fileservice"], [], true),
  mod("coturn", ["network:nat", "nextcloud:fileservice"]),
  mod("nextcloud", ["cluster:vm", "identity:identity"], ["logging:logs"], true),
];
{
  const o = installOrder(collab);
  check(o.order.join(",") === "nextcloud,coturn,euro-office,nextcloud-hpb" && o.cycle.length === 0,
    `dependsOn order inside the stack, ties by name (${o.order.join(",")})`);
  const soft = installOrder([mod("b", [], ["a:x"]), mod("a")]);
  check(soft.order.join(",") === "a,b", "integratesWith orders too, so the integration is wired on first install");
  const cyc = installOrder([mod("a", ["b:x"]), mod("b", ["a:y"]), mod("c")]);
  check(cyc.order.join(",") === "c" && cyc.cycle.join(",") === "a,b", "a cycle is returned apart, never guessed");
}

{
  const facts = {
    instanceOf: (m: string) => m,
    installed: (i: string) => i === "nextcloud",
    providerInstalled: (p: string) => ["cluster", "network", "logging"].includes(p),
    vmidUsed: () => false,
  };
  const p = planStack(collab, facts);
  check(p.steps[0].action === "skip" && p.steps.slice(1).every((s) => s.action === "install"),
    "an installed module is skipped, the rest installed");
  check(p.missing.length === 1 && p.missing[0].module === "nextcloud" && p.missing[0].dependency === "identity:identity",
    "a dependency outside the stack that is not installed is reported, naming who needs it");
  check(!p.missing.some((m) => m.dependency.startsWith("logging")), "integratesWith outside the stack is optional, never missing");
  const eo = p.steps.find((s) => s.module === "euro-office");
  check(eo?.action === "install" && eo.handSteps, "a module whose INSTALL.md leaves steps is flagged in the plan");
  const env = planStack(collab, { ...facts, instanceOf: (m) => `${m}-test`, installed: () => false });
  check(env.steps.every((s) => s.action === "install"), "in another environment the base instance does not count as installed");
}

{
  // VMIDs: the declared one when free, else the first free one in its block of ten.
  const vm = [mod("forgejo"), mod("runner", ["forgejo:git"])];
  vm[0].vmid = 350; vm[1].vmid = 360;
  const taken = new Set([350, 351, 360]);
  const p = planStack(vm, { instanceOf: (m) => `${m}-test`, installed: () => false, providerInstalled: () => true, vmidUsed: (v) => taken.has(v) });
  const f = p.steps[0], r = p.steps[1];
  check(f.action === "install" && f.vmid === 352, "the declared VMID taken: the first free one in its block (350 → 352)");
  check(r.action === "install" && r.vmid === 361, "…per module");
  const free = planStack([vm[0]], { instanceOf: (m) => m, installed: () => false, providerInstalled: () => true, vmidUsed: () => false });
  check(free.steps[0].action === "install" && free.steps[0].vmid === undefined, "a free declared VMID is used as is");
  const full = planStack([vm[0]], { instanceOf: (m) => m, installed: () => false, providerInstalled: () => true, vmidUsed: (v) => v >= 350 && v <= 359 });
  check(full.noVmid.join(",") === "forgejo", "a full block is refused, not spilled into the next module's");
}

check(hasHandSteps("# x\n\n## Post-install\n\nDo this.") && hasHandSteps("## First-Time Setup\n") && !hasHandSteps("## Install\n## Verification\n"),
  "hand steps: a Post-install, First-Time Setup or Configure section");

// The order agrees with every stack's generated INSTALL.md.
{
  const MODULE_MANAGER = join(__dirname, "..", "..", "..", "..", "..");
  const SRC = join(MODULE_MANAGER, "..", "..", "..", "..");
  const cat = JSON.parse(readFileSync(join(SRC, "module-catalog.json"), "utf8")) as {
    modules: { moduleName: string; moduleJson: string; stack?: string }[];
  };
  const stacks = [...new Set(cat.modules.map((e) => e.stack ?? ""))].filter((s) => s && !["foundation", "template", "test"].includes(s));
  for (const stack of stacks.sort()) {
    const mods = cat.modules.filter((e) => e.stack === stack).map((e) => {
      const mj = JSON.parse(readFileSync(join(SRC, "..", e.moduleJson), "utf8")) as Record<string, string[]>;
      return mod(e.moduleName, mj.dependsOn ?? [], mj.integratesWith ?? []);
    });
    const doc = join(SRC, stack, "INSTALL.md");
    if (!existsSync(doc)) continue;
    const listed = [...readFileSync(doc, "utf8").matchAll(/^\| \d+(?: ⚠ cycle)? \| \[([^\]]+)\]/gm)].map((m) => m[1]);
    const ours = installOrder(mods).order;
    check(listed.join(",") === ours.join(","), `${stack}: the order is ${stack}/INSTALL.md's (${ours.join(",")})`);
  }
}

console.log(`\nResults: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
