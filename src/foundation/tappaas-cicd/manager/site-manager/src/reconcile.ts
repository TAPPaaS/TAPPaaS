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
//       *.json) and each is driven via `environment-manager reconcile <env>
//       --deep --skip-network` — verb-first, and skipping the network pass the
//       network leg above already ran system-wide (#461).
//
// The engine depends only on SiteClient (injected) — pure planning + apply,
// exactly like people-manager/src/reconcile.ts.

import {
  Site,
  SiteAction,
  SiteApplyFailure,
  SiteApplyResult,
  SiteClient,
  SitePlan,
} from "./types";

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
  // Which own-concern slice to plan (the scoped subverbs `node reconcile` /
  // `repository reconcile` plan just their slice; full `reconcile` = "all").
  scope?: "all" | "nodes" | "repositories";
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

  const scope = opts.scope ?? "all";

  // ── (1a) own concern: capture live cluster nodes into site.json ──────
  // The join path (cluster/install.sh on a NEW node) cannot write this
  // site.json, so membership is reconciled from the cicd side: nodes in the
  // live cluster but missing from .hardware.nodes are REGISTERED (with empty
  // storagePools — the operator declares pools); site.json nodes that left
  // the cluster are WARNED about, never auto-removed. Fixes the 2-node gap
  // where HA fold / zone distribution could not see a joined node
  // (docs/design/node-provisioning.md, Phase N1).
  if (scope !== "repositories") {
    const known = site.hardware.nodes.map((n) => n.name);
    const live = client.clusterNodes(known);
    if (live === null) {
      warnings.push("cluster unreachable — node inventory not reconciled this run");
    } else {
      const knownSet = new Set(known);
      for (const n of live) {
        if (!knownSet.has(n)) {
          // Discover the node's tankXY pools at PLAN time (create-site.sh's
          // zpool-list discovery) so registration lands complete.
          const pools = client.nodeStoragePools(n) ?? [];
          const poolTxt =
            pools.length > 0
              ? `storagePools: [${pools.join(", ")}] (discovered)`
              : "storagePools: [] — pool discovery failed; declare via 'node add' or edit";
          actions.push({
            kind: "register-node",
            target: `node ${n} → register in site.json (${poolTxt})`,
            apply: (c) => {
              c.registerNode(opts.siteFile, n, pools);
              return 0;
            },
          });
        }
      }
      for (const n of known) {
        if (!live.includes(n)) {
          warnings.push(
            `site.json node '${n}' is not in the live cluster (removed? renamed?) — not auto-removed; use 'node delete ${n}' if intentional`,
          );
          continue;
        }
        // Known node: fill EMPTY storagePools from discovery (a node
        // registered before discovery existed, or pools created later).
        // Never overwrite a non-empty list — an operator-authored subset is
        // legitimate; disagreement is a warning only.
        const declared = site.hardware.nodes.find((x) => x.name === n)?.storagePools ?? [];
        const livePoolList = client.nodeStoragePools(n);
        if (livePoolList === null) continue;
        if (declared.length === 0 && livePoolList.length > 0) {
          actions.push({
            kind: "update-node-pools",
            target: `node ${n} → fill storagePools [${livePoolList.join(", ")}] (discovered; was empty)`,
            apply: (c) => {
              c.setNodePools(opts.siteFile, n, livePoolList);
              return 0;
            },
          });
        } else if (
          declared.length > 0 &&
          declared.slice().sort().join(",") !== livePoolList.slice().sort().join(",")
        ) {
          warnings.push(
            `node '${n}': site.json declares pools [${declared.join(", ")}] but the node reports [${livePoolList.join(", ")}] — not auto-changed`,
          );
        }
      }
    }
  }

  // ── (1b) own concern: converge repositories[] to live clones ──────────
  if (scope !== "nodes") for (const repo of site.repositories) {
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
        apply: (c) => {
          c.cloneRepo(repo.url, path, branch);
          return 0;
        },
      });
      continue;
    }
    const cur = client.currentBranch(path);
    if (cur !== null && cur !== branch) {
      actions.push({
        kind: "checkout-repo",
        target: `repository ${repo.name} → checkout ${branch} (was ${cur})`,
        apply: (c) => {
          c.checkoutRepo(path, branch);
          return 0;
        },
      });
    }
  }

  // ── (2) --deep cascade to dependent managers ─────────────────────────
  // Order: people → network → (every) environment. people/network are single
  // bins; environments fan out, one deep reconcile per registered environment.
  if (opts.deep) {
    const apply = opts.apply;
    const envs = client.listEnvironments();
    for (const mgr of CASCADE_ORDER) {
      // Say what the network leg actually covers (#461): it is ONE system-wide
      // pass over every zone and plane, not one pass per environment. The
      // per-environment legs below depend on this leg running first — if
      // CASCADE_ORDER ever drops "network", their --skip-network must go too.
      const scope =
        mgr === "network"
          ? ` (system-wide: 1 pass over all zones/planes, covering all ${envs.length} environment(s))`
          : "";
      actions.push({
        kind: ("cascade-" + mgr) as SiteAction["kind"],
        target: `cascade → ${mgr} reconcile${apply ? " --apply" : " (preview)"}${scope}`,
        apply: (c) => c.cascade(mgr, apply),
      });
    }
    for (const env of envs) {
      actions.push({
        kind: "cascade-environment",
        target:
          `cascade → environment ${env} reconcile --deep --skip-network` +
          `${apply ? " --apply" : " (preview)"}`,
        apply: (c) => c.cascadeEnvironment(env, apply),
      });
    }
  }

  return { actions, warnings };
}

// Apply a plan via the client. Returns what converged and what did not.
//
// A failing action is COLLECTED, not thrown: the cascade continues so one bad
// environment does not strand the ones planned after it (the #454 lesson). A
// non-zero rc from a cascade counts as a failure — previously every action was
// counted as applied regardless, so a --deep run that converged nothing still
// printed "Applied N action(s)".
export function applyPlan(client: SiteClient, plan: SitePlan): SiteApplyResult {
  let applied = 0;
  const failures: SiteApplyFailure[] = [];
  for (const a of plan.actions) {
    try {
      const rc = a.apply(client);
      if (rc === 0) applied++;
      else failures.push({ target: a.target, error: `exit ${rc}` });
    } catch (e) {
      failures.push({ target: a.target, error: e instanceof Error ? e.message : String(e) });
    }
  }
  return { applied, failures };
}
