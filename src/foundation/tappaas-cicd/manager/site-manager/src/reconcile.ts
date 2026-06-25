// reconcile.ts — the site reconcile engine (ADR-007 P2).
//
// `site reconcile` converges the site's OWN concern, and with `--deep` cascades
// to its dependents. Per the design doc (§Reconcile cascade):
//
//   site reconcile         → site.json / nodes / repositories only
//   site reconcile --deep  → people + network + (every) environment --deep
//
// Two layers:
//   (1) own concern — validate site.json is well-formed, then converge each
//       repository[] entry to a live clone: clone if missing, checkout if the
//       branch drifts. (This is the steady-state half of repository.sh's
//       clone/checkout logic, expressed as idempotent reconcile actions.)
//   (2) --deep cascade — shell out to the dependent manager bins in dependency
//       order: people → network → (every) environment. We do NOT reimplement
//       them (people-manager / network-manager / environment-manager own that
//       logic). Environments are enumerated from the site (config/environments/
//       *.json) and each is driven via `environment-manager <env> reconcile
//       --deep`.
//
// The engine depends only on SiteClient (injected) — pure planning + apply,
// exactly like people-manager/src/reconcile.ts.

import { Site, SiteAction, SiteClient, SitePlan } from "./types";

// The single-bin dependent managers a `--deep` site reconcile drives first, in
// order. Environments follow (per-env fan-out — see computePlan), so the full
// cascade order is people → network → (every) environment.
export const CASCADE_ORDER: ("people" | "network")[] = ["people", "network"];

export interface ReconcileOpts {
  // --deep: also reconcile dependent managers (people, network, environments).
  deep: boolean;
  // --apply: commit (default is preview / dry-run), matching network-manager.
  apply: boolean;
  // The site.json being reconciled (for the validate action).
  siteFile: string;
}

// Compute the reconcile plan for a loaded Site against the live system as seen
// through the client. Pure — emits actions; apply happens in applyPlan.
export function computePlan(site: Site, client: SiteClient, opts: ReconcileOpts): SitePlan {
  const actions: SiteAction[] = [];
  const warnings: string[] = [];

  // ── (0) site.json must be well-formed before we touch anything ────────
  const errs = client.validateSite(opts.siteFile);
  if (errs.length > 0) {
    for (const e of errs) warnings.push(`site.json validation: ${e}`);
  }

  // ── (1) own concern: converge repositories[] to live clones ──────────
  for (const repo of site.repositories) {
    const branch = repo.branch ?? "stable";
    const path = repo.path;
    if (!path) {
      warnings.push(`repository '${repo.name}': no .path — cannot reconcile clone`);
      continue;
    }
    if (!client.repoCloneExists(path)) {
      actions.push({
        kind: "clone-repo",
        target: `repository ${repo.name} → clone ${repo.url} @ ${branch}`,
        apply: (c) => c.cloneRepo(repo.url, path, branch),
      });
      continue;
    }
    const cur = client.currentBranch(path);
    if (cur !== null && cur !== branch) {
      actions.push({
        kind: "checkout-repo",
        target: `repository ${repo.name} → checkout ${branch} (was ${cur})`,
        apply: (c) => c.checkoutRepo(path, branch),
      });
    }
  }

  // ── (2) --deep cascade to dependent managers ─────────────────────────
  // Order: people → network → (every) environment. people/network are single
  // bins; environments fan out, one deep reconcile per registered environment.
  if (opts.deep) {
    const apply = opts.apply;
    for (const mgr of CASCADE_ORDER) {
      actions.push({
        kind: ("cascade-" + mgr) as SiteAction["kind"],
        target: `cascade → ${mgr} reconcile${apply ? " --apply" : " (preview)"}`,
        apply: (c) => c.cascade(mgr, apply),
      });
    }
    for (const env of client.listEnvironments()) {
      actions.push({
        kind: "cascade-environment",
        target: `cascade → environment ${env} reconcile --deep${apply ? " --apply" : " (preview)"}`,
        apply: (c) => c.cascadeEnvironment(env, apply),
      });
    }
  }

  return { actions, warnings };
}

// Apply a plan via the client. Returns count applied.
export function applyPlan(client: SiteClient, plan: SitePlan): number {
  for (const a of plan.actions) a.apply(client);
  return plan.actions.length;
}
