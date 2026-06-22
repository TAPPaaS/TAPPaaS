// types.ts — the network domain model (the zones.json Zone shape), the
// PlaneClient interface (the controller boundary network-manager reconciles
// through), and the reconcile Plan/Delta shapes.
//
// Mirrors people-manager's split: the reconcile engine depends ONLY on the
// PlaneClient interface; production uses CliPlaneClient (spawnSync of the 4
// plane bins), tests inject an in-memory FakePlaneClient.

// ── Zone model (one entry in zones.json) ─────────────────────────────
// zones.json is a flat object keyed by zone name; each value is a Zone. Keys
// beginning with "_" (e.g. "_README") are documentation blocks, NOT zones, and
// are skipped on load.
export interface Zone {
  name: string; // the object key, mirrored in for convenience
  type?: string;
  typeId?: string;
  subId?: string;
  vlantag?: number;
  ip?: string;
  bridge?: string;
  state?: string; // Active | Inactive | Manual | Mandatory | Disabled
  "access-to"?: string[];
  "pinhole-allowed-from"?: string[];
  description?: string;
  parent?: string;
  variant?: string;
  SSID?: string;
  // Preserve any unknown fields so a load→edit→save round-trips losslessly.
  [k: string]: unknown;
}

// The loaded zones document: the raw JSON object (incl. "_*" doc blocks) plus
// an indexed view of the real zones. We keep `raw` so writes preserve doc
// blocks and field ordering is JSON-stable.
export interface ZonesDoc {
  raw: Record<string, unknown>; // the full parsed object, doc blocks included
  zones: Map<string, Zone>; // real zones only (no "_*")
}

// ── Planes ────────────────────────────────────────────────────────────
// The four infrastructure planes, in dependency order (ADR-008 §8): L3 first
// so a guest can get an IP, then L2 (proxmox node, then switch), then WiFi.
export type Plane = "opnsense" | "proxmox" | "switch" | "ap";
export const PLANE_ORDER: Plane[] = ["opnsense", "proxmox", "switch", "ap"];

// ── PlaneClient — the controller boundary ─────────────────────────────
// One method per plane. Each returns a PlaneResult describing what the plane
// reported. The reconcile engine depends ONLY on this interface.
//
// `apply=false` is dry-run (report drift, mutate nothing); `apply=true`
// converges. `zonesFile` is the path to the desired-state zones.json the
// opnsense plane reads (the L2/WiFi planes read their own desired-state files
// authored elsewhere, but take the same call shape for uniformity).
export interface PlaneClient {
  reconcile(plane: Plane, apply: boolean, zonesFile: string): PlaneResult;
}

// Outcome status for a single plane, derived from the controller's rc per the
// shared convention (rc 0 = in-sync, 2 = drift/needs-manual, 1/other = error).
export type PlaneStatus = "in-sync" | "drift" | "needs-manual" | "error" | "skipped";

export interface PlaneResult {
  plane: Plane;
  status: PlaneStatus;
  rc: number; // raw exit code from the controller (or -1 if not run)
  // Human-readable note for the per-plane line in the report.
  message: string;
}

// ── Reconcile run report ──────────────────────────────────────────────
export interface ReconcileReport {
  apply: boolean;
  results: PlaneResult[];
  // Planes that constitute an overall failure (error, or still-drifting after
  // apply). Empty ⇒ the run is a success.
  failed: Plane[];
}
