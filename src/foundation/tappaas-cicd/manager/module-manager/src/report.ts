// report.ts — the manager's client for `services/<svc>/report-service.sh`
// (ADR-020 D7, the actual-state read).
//
// One read, several consumers. `inspect` (report), `modify` (apply) and the
// health checks all take their idea of ACTUAL state from the provider's own
// reporter rather than each shelling their own `qm config` and parsing it.
// Before ADR-020 the parsing existed twice — in `cluster:vm/update-service.sh`
// and (in TypeScript) in `inspect.ts` — and the two had already drifted: the
// bash one could not read a container's `hwaddr=` MAC (#465, #550).
//
// What this file adds over "run a script and parse JSON" is the ERROR MODEL.
// The reporter's exit codes name distinct operator actions, and the caller has
// distinct things to say about each: an unreachable cluster is not the same as
// a guest that is intentionally absent (an archived module), which is not the
// same as a guest that is there but unreadable (#526). Collapsing them into one
// "failed to get VM config" is exactly what #526 had to undo.

import { existsSync } from "fs";
import { join } from "path";
import { captureResult } from "../../../lib/ts/src/exec";
import { getModuleDir, resolveProviderModule } from "./config";

// Which Proxmox CLI owns a guest, and therefore which service reports it.
export type GuestType = "qemu" | "lxc";

// The service directory each guest type's reporter lives in, under the
// `cluster` provider module.
const SERVICE_FOR: Record<GuestType, string> = { qemu: "vm", lxc: "lxc" };

export type ReportOutcome =
  | { kind: "ok"; actual: Record<string, string>; guest: GuestType }
  // No reporter on disk for this provider/service — the provider has not been
  // migrated to the ADR-020 contract yet (P5). Distinct from every failure: the
  // caller may legitimately fall back rather than report a problem.
  | { kind: "no-reporter"; path: string }
  | { kind: "cluster-unreachable" }
  | { kind: "not-present" }
  | { kind: "unreadable"; detail: string }
  | { kind: "error"; rc: number; detail: string };

// Locate a provider service's report-service.sh. Environment-aware, exactly as
// the dependency-service checks resolve a provider (#438).
export function reporterPath(
  configDir: string,
  provider: string,
  service: string,
  environment: string,
): string | null {
  const module = resolveProviderModule(configDir, provider, environment);
  const dir = getModuleDir(configDir, module);
  if (!dir) return null;
  const path = join(dir, "services", service, "report-service.sh");
  return existsSync(path) ? path : null;
}

// Run ANY provider service's reporter and classify the result. The guest-typed
// wrapper below is the cluster-specific case; every other provider that grows a
// reporter (P5) is reached through this one.
export function runServiceReporter(
  configDir: string,
  module: string,
  provider: string,
  service: string,
  environment: string,
  guest: GuestType = "qemu",
): ReportOutcome {
  const path = reporterPath(configDir, provider, service, environment);
  if (!path) return { kind: "no-reporter", path: `${provider}/services/${service}/report-service.sh` };

  const r = captureResult(path, [module]);
  if (!r.ran) return { kind: "error", rc: -1, detail: r.stderr.trim() || "spawn failed" };

  switch (r.rc) {
    case 0:
      break;
    case 4:
      return { kind: "cluster-unreachable" };
    case 5:
      return { kind: "not-present" };
    case 6:
      return { kind: "unreadable", detail: r.stderr.trim() };
    default:
      return { kind: "error", rc: r.rc, detail: [r.stdout, r.stderr].filter((s) => s.trim()).join("\n") };
  }

  // A zero exit must carry one JSON object. Anything else is a broken reporter,
  // reported as such rather than degraded into an empty actual state — "we did
  // not look" must never render as "the guest has nothing set".
  let parsed: unknown;
  try {
    parsed = JSON.parse(r.stdout);
  } catch (e) {
    return { kind: "error", rc: 0, detail: `report-service.sh emitted invalid JSON: ${(e as Error).message}` };
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { kind: "error", rc: 0, detail: "report-service.sh did not emit a JSON object" };
  }
  const actual: Record<string, string> = {};
  for (const [k, v] of Object.entries(parsed as Record<string, unknown>)) {
    actual[k] = typeof v === "string" ? v : v === null || v === undefined ? "" : String(v);
  }
  return { kind: "ok", actual, guest };
}

// The cluster case: pick the reporter by guest type.
export function runReporter(
  configDir: string,
  module: string,
  guest: GuestType,
  environment: string,
): ReportOutcome {
  return runServiceReporter(configDir, module, "cluster", SERVICE_FOR[guest], environment, guest);
}

// Report a guest whose TYPE is only declared, not observed.
//
// `dependsOn` is a statement of intent; Proxmox holds the truth. The old inspect
// asked the cluster first and used the declaration only as a fallback. Here the
// declared type picks a reporter, and a "not present" answer is retried against
// the other type — so a module declaring cluster:vm whose guest is really a
// container is still reported, and the caller is told the declaration is wrong
// rather than being handed a bare "not found".
export interface ReportResult {
  outcome: ReportOutcome;
  // Set when the guest was found under a type OTHER than the declared one.
  declaredGuest?: GuestType;
}

export function reportGuest(
  configDir: string,
  module: string,
  declared: GuestType,
  environment: string,
): ReportResult {
  const first = runReporter(configDir, module, declared, environment);
  if (first.kind !== "not-present") return { outcome: first };

  const other: GuestType = declared === "qemu" ? "lxc" : "qemu";
  const second = runReporter(configDir, module, other, environment);
  if (second.kind === "ok") return { outcome: second, declaredGuest: declared };
  // The other type has nothing either: the guest really is absent. Report the
  // FIRST answer, which is the one phrased in terms of what the module declares.
  return { outcome: first };
}
