// fake-site.ts — a Runner that answers the managers' verbs from hrossen's
// captured outputs (test/fixtures, 2026-10-17), and records what was run.

import { readFileSync } from "fs";
import { join } from "path";
import { ExecResult } from "../../../lib/ts/src/exec";
import { Runner } from "../../src/run";

export const FIX = process.env.CONSOLE_FIXTURES ?? "test/fixtures";
const file = (f: string): string => readFileSync(join(FIX, f), "utf8");

export interface FakeSite {
  run: Runner;
  calls: string[];
  fail: Set<string>; // "bin verb" prefixes that exit 1
}

export function fakeSite(): FakeSite {
  const calls: string[] = [];
  const fail = new Set<string>();
  const ok = (stdout: string): ExecResult => ({ rc: 0, stdout, stderr: "", ran: true });
  const run: Runner = async (bin, args) => {
    const cmd = `${bin} ${args.join(" ")}`;
    calls.push(cmd);
    for (const f of fail) if (cmd.startsWith(f)) return { rc: 1, stdout: "", stderr: "[Error] failed on purpose", ran: true };
    switch (`${bin} ${args[0]}`) {
      case "health-manager validate":
        return { rc: 1, stdout: file("validate.json"), stderr: "", ran: true }; // a gate fails: exit 1, full document
      case "health-manager report":
        return { rc: 1, stdout: "", stderr: "[Error] no security scan yet — run: health-manager scan security", ran: true };
      case "module-manager list":
        return ok(file("modules.json"));
      case "module-manager show":
        return ok(JSON.stringify({ moduleSource: `/src/${args[1]}`, status: "Testing" }));
      case "module-manager resolve":
        return ok(JSON.stringify({ module: args[1], fields: {} }));
      case "module-manager fields":
        return ok(JSON.stringify({ module: args[1], fields: [{ field: "memory", coordinate: "cluster:vm", class: "in-place", settable: true, reason: null, value: "8192" }], warnings: [] }));
      case "module-manager drift":
        return ok(JSON.stringify({ module: args[1], services: {} }));
      case "backup-manager list":
        return ok(file("backup.json"));
      case "backup-manager show":
        return ok(JSON.stringify({ module: args[1], enabled: true, inPbsJob: true }));
      case "backup-manager coverage":
        return ok(JSON.stringify({ reachable: true, module: args[1], jobs: [] }));
      case "backup-manager peers":
        return ok(JSON.stringify([{ name: "rasmus", role: "remote" }]));
      case "network-manager topology":
        return ok(file("topology.json"));
      case "environment-manager list":
        return ok(file("environments.json"));
      case "site-manager site":
        return ok(JSON.stringify({ name: "rossen", channel: "unstable" }));
      case "site-manager node":
        return ok(args[1] === "list" ? JSON.stringify([{ name: "tappaas1" }, { name: "tappaas2" }]) : "[]");
      case "site-manager repository":
        return ok("[]");
      case "identity-manager org":
      case "identity-manager group":
      case "identity-manager user":
      case "identity-manager role": {
        const ids: Record<string, Record<string, Record<string, unknown>>> = {
          org: { rossen: { name: "rossen", owner: "lars", parentOrg: null } },
          group: { users: { name: "users", ownerOrg: "rossen", roles: ["user"] }, "authentik Admins": { name: "authentik Admins", ownerOrg: "rossen", roles: [] } },
          user: { lars: { name: "lars", memberOf: ["users", "authentik Admins"], roles: ["admin", "user"] }, "-x": { name: "-x" } },
          role: { admin: { name: "admin" }, user: { name: "user" } },
        };
        const kind = ids[args[0]];
        if (args[1] === "list") return ok(JSON.stringify(Object.keys(kind)));
        if (args[1] === "show" && kind[args[2]]) return ok(JSON.stringify(kind[args[2]]));
        return { rc: 1, stdout: "", stderr: `[Error] no ${args[0]} '${args[2]}'`, ran: true };
      }
      case "ap-controller list":
        return ok(file("aps.json"));
      case "node-provisioner status":
        return { rc: 1, stdout: "PXE: disabled (no TAPPaaS boot entries; zone 'mgmt')\npending registrations: none\n", stderr: "", ran: true };
      case "journalctl -u":
        return ok(file("sweep-journal.txt"));
      case "systemctl is-active":
        return { rc: 3, stdout: "inactive\n", stderr: "", ran: true };
      default:
        return { rc: -1, stdout: "", stderr: `${bin}: not in the fake site`, ran: false };
    }
  };
  return { run, calls, fail };
}
