// reconcile.ts — the environment reconcile engine (ADR-007 P3 cascade).
//
// `environment reconcile <env>`:
//   shallow (default) → reconcile the environment setup + its associated zone,
//                        by shelling out to network-manager (the network plane
//                        owner). network-manager converges all zones in one
//                        pass; the environment's zone is part of that.
//   --deep            → the above + reconcile EVERY module that consumes this
//                        environment (module reconcile, the leaf re-apply),
//                        shelling out to module-manager per module.
//
// Each `reconcile` is idempotent, so re-touching a shared dependency (the
// network) is harmless. The engine depends only on the NetworkClient /
// ModuleClient interfaces (injected) — pure planning, then apply.

import {
  Action,
  Environment,
  ModuleClient,
  NetworkClient,
  Plan,
} from "./types";

// Compute the reconcile plan for one environment.
//   deep=false → just the network reconcile (env + its zone).
//   deep=true  → network reconcile + one module reconcile per consuming module.
export function computePlan(
  env: Environment,
  net: NetworkClient,
  mod: ModuleClient,
  deep: boolean,
): Plan {
  const actions: Action[] = [];
  const warnings: string[] = [];

  const zone = env.network.zone;
  if (!zone) {
    warnings.push(`environment '${env.name}': no network.zone — nothing to reconcile`);
  } else if (!net.zoneExists(zone)) {
    // The zone the environment points at is not in zones.json. The bash
    // validate path errors here; for reconcile we surface a warning and still
    // run the network reconcile (which is the owner of zone convergence).
    warnings.push(
      `environment '${env.name}': zone '${zone}' not present in zones.json — network reconcile may not converge it`,
    );
  }

  actions.push({
    kind: "reconcile-network",
    target: `network (zone '${zone || "?"}' of environment '${env.name}')`,
  });

  if (deep) {
    const modules = mod.modulesForEnvironment(env.name);
    for (const m of modules) {
      actions.push({ kind: "reconcile-module", target: `module '${m}'` });
    }
    if (modules.length === 0) {
      warnings.push(`environment '${env.name}': no deployed modules consume it (--deep: nothing downstream)`);
    }
  }

  return { actions, warnings };
}

// Apply a plan via the clients. Returns count applied.
export function applyPlan(
  _env: Environment,
  plan: Plan,
  net: NetworkClient,
  mod: ModuleClient,
  apply: boolean,
): number {
  let n = 0;
  for (const a of plan.actions) {
    if (a.kind === "reconcile-network") {
      net.reconcileNetwork(apply);
      n++;
    } else if (a.kind === "reconcile-module") {
      // target is `module '<name>'` — recover the name.
      const m = a.target.replace(/^module '/, "").replace(/'$/, "");
      mod.reconcileModule(m, apply);
      n++;
    }
  }
  return n;
}
