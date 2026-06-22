// reconcile.ts — the 4-plane reconcile orchestration (port of `zone-reconcile`,
// ADR-008 §8).
//
// Reads zones.json (the desired state network-manager owns) and reconciles it
// onto EVERY plane in dependency order, then aggregates a per-plane status. A
// zone change is only "done" when every plane is in sync — this is what makes
// cross-stack sync a guarantee rather than a hope (closes the #335 / #372 /
// #373 class of "VM up, but silently no IP").
//
// Dependency order (ADR-008): opnsense (L3) → proxmox (L2 node) → switch (L2
// inter-node) → ap (WiFi). L3 must exist before L2 so a guest can get an IP.
//
// The engine depends only on PlaneClient (injected) — pure orchestration.

import {
  Plane,
  PLANE_ORDER,
  PlaneClient,
  PlaneResult,
  ReconcileReport,
} from "./types";

export interface ReconcileOpts {
  apply: boolean;
  only?: Plane; // run a single plane
  zonesFile: string;
}

// Run the reconcile pass. Returns a structured report; the CLI prints it.
export function reconcileAll(client: PlaneClient, opts: ReconcileOpts): ReconcileReport {
  const planes = opts.only ? [opts.only] : PLANE_ORDER;
  const results: PlaneResult[] = [];
  for (const plane of planes) {
    results.push(client.reconcile(plane, opts.apply, opts.zonesFile));
  }
  const failed = computeFailed(results, opts.apply);
  return { apply: opts.apply, results, failed };
}

// A plane "fails" the run when:
//   - status is error (controller error / not on PATH), OR
//   - status is drift|needs-manual AND we were applying (still not converged).
// In dry-run, drift is REPORTED, not a failure (matches zone-reconcile).
export function computeFailed(results: PlaneResult[], apply: boolean): Plane[] {
  const failed: Plane[] = [];
  for (const r of results) {
    if (r.status === "error") {
      failed.push(r.plane);
    } else if (apply && (r.status === "drift" || r.status === "needs-manual")) {
      // proxmox can self-apply, so ANY non-in-sync after --apply is a hard
      // failure (it "still drifts"). switch/ap "needs-manual" is expected —
      // they can't always self-apply — so we surface but do NOT fail on it,
      // mirroring zone-reconcile (which only FAILED proxmox on rc!=0,2 and
      // merely warned for switch/ap rc 2).
      if (r.plane === "proxmox") failed.push(r.plane);
    }
  }
  return failed;
}
