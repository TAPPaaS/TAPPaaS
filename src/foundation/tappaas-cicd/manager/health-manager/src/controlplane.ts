// controlplane.ts — the control-plane-trust gate (ADR-035 D7).
//
// A module may bring its own controllers and managers; module-manager links them
// into ~/bin and records them in ~/config/control-plane.json, with the
// repository each came from and whether that repository's release was verified
// (ADR-033). A controller from an unverified repository that plugs into a
// foundation manager is allowed, and said: a WARN row per such controller, kept
// for as long as it is so. Never FAIL — the install already warned, and the
// operator chose it.
//
//   no registry                         skip
//   no component from a module          pass
//   all verified, or none plugs into a foundation manager   pass
//   an unverified one that does         warn, one row each

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { CheckResult, CheckRow } from "./types";

interface Component {
  name: string;
  kind: string;
  module: string;
  repository?: string;
  verified?: boolean;
  plugsInto?: string[];
  instances?: string[];
}

export function checkControlPlaneTrust(configDir: string): CheckResult {
  const f = join(configDir, "control-plane.json");
  if (!existsSync(f)) return { name: "control-plane-trust", status: "skip", detail: "no control-plane registry yet — refresh writes it" };
  let comps: Component[];
  try {
    const r = JSON.parse(readFileSync(f, "utf8")) as { components?: Component[] };
    comps = Array.isArray(r.components) ? r.components : [];
  } catch {
    return { name: "control-plane-trust", status: "warn", detail: `${f} is not readable JSON` };
  }
  const foundation = new Set(comps.filter((c) => c.module === "tappaas-cicd" && c.kind === "manager").map((c) => c.name));
  const contributed = comps.filter((c) => c.module !== "tappaas-cicd");
  if (contributed.length === 0) return { name: "control-plane-trust", status: "pass", detail: "no component from a module" };
  const rows: CheckRow[] = [];
  for (const c of contributed) {
    const into = (c.plugsInto ?? []).filter((m) => foundation.has(m));
    if (c.kind !== "controller" || c.verified === true || into.length === 0) continue;
    rows.push({
      status: "warn",
      text: `${c.name.padEnd(22)}from ${c.repository ?? "an unknown repository"} (module ${c.module}), not a verified release — plugs into ${into.join(", ")}`,
      subject: { kind: "module", name: (c.instances ?? [])[0] ?? c.module },
    });
  }
  const verified = contributed.filter((c) => c.verified === true).length;
  const detail = `${contributed.length} component(s) from modules: ${verified} verified` + (rows.length ? `, ${rows.length} unverified in a foundation manager` : "");
  return { name: "control-plane-trust", status: rows.length ? "warn" : "pass", detail, rows };
}
