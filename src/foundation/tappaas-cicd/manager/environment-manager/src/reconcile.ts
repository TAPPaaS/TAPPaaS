// reconcile.ts — the environment reconcile engine (ADR-007 P3 cascade).
//
// `environment reconcile <env>`:
//   shallow (default) → trigger a network convergence by shelling out to
//                        network-manager (the network plane owner).
//   --deep            → the above + reconcile EVERY module that consumes this
//                        environment (module reconcile, the leaf re-apply),
//                        shelling out to module-manager per module.
//
// The network half is SYSTEM-WIDE, not per-environment (#461): network-manager
// reconcile has no zone or environment filter, so it converges every zone on
// every plane and this environment's zone is merely included. The plan says so,
// and `--skip-network` lets a caller that has already run the system-wide pass
// (site-manager's --deep cascade) avoid repeating it once per environment.
//
// Each `reconcile` is idempotent, so re-touching a shared dependency (the
// network) is harmless — it is wasteful, not wrong. The engine depends only on
// the NetworkClient / ModuleClient interfaces (injected) — pure planning, then
// apply.

import {
  Action,
  ApplyFailure,
  ApplyResult,
  Environment,
  ModuleClient,
  NetworkClient,
  NetworkUnreachable,
  Plan,
} from "./types";

export interface ReconcileOpts {
  // --deep: also reconcile every module that consumes this environment.
  deep: boolean;
  // --skip-network: omit the system-wide network reconcile because the caller
  // already ran it. Only safe when that is actually true — see site-manager.
  skipNetwork: boolean;
  // The organization to adopt when this environment has no ownerOrg. The caller
  // resolves it (and confirms it exists) so the engine stays pure. Undefined =
  // no candidate could be resolved, in which case an empty ownerOrg is reported
  // as a warning rather than silently left alone.
  ownerOrgCandidate?: string;
  // Whether the environment being reconciled is the DEFAULT environment
  // (site.json .defaultEnvironment). The identity module's public self-config
  // tracks the default environment's domain, so a --deep reconcile of the
  // default env must also re-point it (#474). Absent ⇒ false.
  isDefaultEnv?: boolean;
}

// Compute the reconcile plan for one environment.
//   deep=false → just the (system-wide) network reconcile.
//   deep=true  → network reconcile + one module reconcile per consuming module.
export function computePlan(
  env: Environment,
  net: NetworkClient,
  mod: ModuleClient,
  opts: ReconcileOpts,
): Plan {
  const actions: Action[] = [];
  const warnings: string[] = [];
  const notes: string[] = [];

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

  if (opts.skipNetwork) {
    notes.push(
      "network reconcile SKIPPED (--skip-network): the system-wide network pass is the caller's " +
        `responsibility this run; zone '${zone || "?"}' converges there, not here.`,
    );
  } else {
    // NOT scoped to this environment — say so in the label itself (#461). The
    // zone is named as what the pass happens to include, never as its extent.
    actions.push({
      kind: "reconcile-network",
      scope: "system-wide",
      target:
        "network — ALL zones, ALL planes (system-wide; " +
        `zone '${zone || "?"}' of environment '${env.name}' converges as part of it)`,
    });
    notes.push(
      "the network reconcile is system-wide: network-manager takes no zone or environment " +
        "filter, so one run converges the whole platform. Running it once per environment " +
        "repeats the identical operation — use --skip-network when a caller already ran it.",
    );
  }

  // ownerOrg backfill. The bootstrap writes "" because it runs before any
  // organization exists; the only other repair (rest-of-foundation.sh) is
  // nested inside a "config/people is empty" guard, so it can fire exactly once
  // and never again. Nothing on the update path checks the field at all, which
  // is how an environment can stay schema-invalid indefinitely. Reconcile is
  // the convergence verb, so it is where the repair belongs.
  if (!env.ownerOrg) {
    if (opts.ownerOrgCandidate) {
      actions.push({
        kind: "backfill-owner-org",
        scope: "environment",
        target: `ownerOrg = '${opts.ownerOrgCandidate}' on environment '${env.name}' (was empty)`,
        value: opts.ownerOrgCandidate,
      });
    } else {
      warnings.push(
        `environment '${env.name}': ownerOrg is empty and no organization could be resolved ` +
          `— create one under people/organizations/, or set it with ` +
          `\`environment-manager modify ${env.name} --owner <org>\``,
      );
    }
  }

  if (opts.deep) {
    const modules = mod.modulesForEnvironment(env.name);
    for (const m of modules) {
      actions.push({ kind: "reconcile-module", scope: "environment", target: `module '${m}'` });
    }
    if (modules.length === 0) {
      warnings.push(`environment '${env.name}': no deployed modules consume it (--deep: nothing downstream)`);
    }
    // The identity module lives in the mgmt zone (environment: null), so it is
    // never in modulesForEnvironment(<app env>) — yet its Authentik self-config
    // (app launch URL, proxy external_host, oauth2 redirect_uris, outpost
    // authentik_host) is built from the DEFAULT environment's domain. Reconcile
    // it here when the default environment is the one changing, so a domain
    // change re-points those objects (#474). Idempotent, guarded on deployment,
    // and de-duplicated in case identity is ever tied to this env directly.
    if (opts.isDefaultEnv && !modules.includes("identity") && mod.moduleDeployed("identity")) {
      actions.push({ kind: "reconcile-module", scope: "environment", target: "module 'identity'" });
      notes.push(
        "identity is reconciled because this is the default environment: its Authentik " +
          "self-config (app launch URL, proxy external_host, oauth2 redirect_uris, outpost " +
          "authentik_host) tracks this environment's domain (#474).",
      );
    }
  }

  return { actions, warnings, notes };
}

// Apply a plan via the clients. Returns the count applied plus any targets that
// ran and failed.
//
// Module failures are COLLECTED, not thrown (#454): a module that fails to
// converge is recorded and the cascade continues with the next one, so one bad
// module no longer strands every module planned after it. Two failures still
// abort the whole pass, because neither is a fault of the target:
//   - NetworkUnreachable — a manager binary is missing on PATH, so every
//     remaining target would fail identically; the caller dies with the
//     "unreachable" message instead of reporting N identical failures.
//   - a failing network reconcile — the shared prerequisite for everything
//     planned after it.
export function applyPlan(
  env: Environment,
  plan: Plan,
  net: NetworkClient,
  mod: ModuleClient,
  apply: boolean,
  // Persist the environment after an in-memory field change. Injected so the
  // engine stays free of filesystem access, exactly like the two clients.
  // Omitted → a planned backfill is reported as a failure rather than silently
  // dropped, because the caller asked for a repair and did not get one.
  writeEnv?: (env: Environment) => void,
): ApplyResult {
  let applied = 0;
  const failures: ApplyFailure[] = [];
  for (const a of plan.actions) {
    if (a.kind === "reconcile-network") {
      net.reconcileNetwork(apply);
      applied++;
    } else if (a.kind === "reconcile-module") {
      // target is `module '<name>'` — recover the name.
      const m = a.target.replace(/^module '/, "").replace(/'$/, "");
      try {
        mod.reconcileModule(m, apply);
        applied++;
      } catch (e) {
        if (e instanceof NetworkUnreachable) throw e;
        failures.push({ target: m, error: e instanceof Error ? e.message : String(e) });
      }
    } else if (a.kind === "backfill-owner-org") {
      if (!a.value) {
        failures.push({ target: `ownerOrg on '${env.name}'`, error: "no organization in the planned action" });
        continue;
      }
      if (!writeEnv) {
        failures.push({
          target: `ownerOrg on '${env.name}'`,
          error: "no environment writer available — backfill planned but not applied",
        });
        continue;
      }
      try {
        env.ownerOrg = a.value;
        writeEnv(env);
        applied++;
      } catch (e) {
        failures.push({
          target: `ownerOrg on '${env.name}'`,
          error: e instanceof Error ? e.message : String(e),
        });
      }
    }
  }
  return { applied, failures };
}
