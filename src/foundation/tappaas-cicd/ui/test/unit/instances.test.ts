// instances.test.ts — a module and its instances (web/src/instances.ts): one
// Installed row per install, a module's installs together, and where Install
// may put it again.

import { defaultInstanceName, groupInstances, installEnvironments, installsOf, instanceOwners } from "../../web/src/instances";
import { check, done } from "./check";

const owner = instanceOwners([
  { modules: [{ name: "vaultwarden", instances: ["vaultwarden", "vaultwarden-test"] }, { name: "deconz", instances: ["deconz-test"] }, { name: "immich", instances: [] }] },
  { modules: [{ name: "backup", instances: ["backup"] }] },
]);
const list = [
  { name: "vaultwarden-test", environment: "test", stack: "security" },
  { name: "deconz-test", environment: "test", stack: "home" },
  { name: "vaultwarden", environment: "rossen", stack: "security" },
  { name: "backup", environment: "mgmt", stack: "foundation" },
  { name: "orphan", environment: "rossen", stack: null },
];
const groups = groupInstances(list, owner);
const vw = groups.find((g) => g.module === "vaultwarden");
check(groups.length === 4, "two vaultwarden instances are one module");
check(vw?.instances.map((i) => i.name).join() === "vaultwarden,vaultwarden-test", "…the instance named like the module first");
const rows = (gs: typeof groups) => installsOf(gs).map((r) => `${r.module}:${r.install.name}@${r.install.environment}`).join(", ");
check(rows([vw!]) === "vaultwarden:vaultwarden@rossen, vaultwarden:vaultwarden-test@test", "one row per install: the one in another environment is a row of its own");
const dz = groups.find((g) => g.module === "deconz");
check(dz !== undefined && rows([dz]) === "deconz:deconz-test@test", "an instance in another environment only is still its module's (deconz-test is deconz)");
const pve = groupInstances([1, 2, 3].map((n) => ({ name: `tappaas${n}`, environment: "mgmt", stack: "foundation" })), instanceOwners([{ modules: [{ name: "pvehost", instances: ["tappaas1", "tappaas2", "tappaas3"] }] }]));
check(pve.length === 1 && rows(pve) === "pvehost:tappaas1@mgmt, pvehost:tappaas2@mgmt, pvehost:tappaas3@mgmt", "several installs in one environment: a row each, all pvehost");
check(installsOf(groups).length === list.length && installsOf(groups).every((r) => r.stack === groups.find((g) => g.module === r.module)?.stack), "every instance is one row, with its module's stack");
check(groups.some((g) => g.module === "orphan" && g.instances.length === 1), "an instance no catalogue claims is a module of its own name");

const envs = ["mgmt", "rossen", "test"];
const e1 = installEnvironments("security", envs, ["rossen"], "rossen");
check(e1.choices.join() === "rossen,test" && e1.initial === "test", "an environment-scoped module: every environment but mgmt, the first it is not in");
const e2 = installEnvironments("security", envs, [], "rossen");
check(e2.initial === "rossen", "…the default environment when it is in none");
const e3 = installEnvironments("foundation", envs, ["mgmt"], "rossen");
check(e3.choices.join() === "mgmt" && e3.initial === "mgmt", "a site-scoped module: mgmt only");
const e4 = installEnvironments("home", envs, ["rossen", "test"], "rossen");
check(e4.choices.join() === "rossen,test" && e4.initial === "rossen", "installed everywhere: still offered (another instance needs --instance)");

check(defaultInstanceName("vaultwarden", "test", "rossen") === "vaultwarden-test", "add --environment test names the instance <module>-test");
check(defaultInstanceName("vaultwarden", "rossen", "rossen") === "vaultwarden" && defaultInstanceName("backup", "mgmt", "rossen") === "backup", "…and the module's own name in the default environment and in mgmt");

done("instances");
