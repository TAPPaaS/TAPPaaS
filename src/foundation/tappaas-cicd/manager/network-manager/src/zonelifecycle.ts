// zonelifecycle.ts — the zone CREATE/DELETE lifecycle (port of zone-controller.sh).
//
// Owns the whole zone lifecycle so every caller (environment-manager, or a
// hands-on operator) goes through one path that cannot forget a plane. It does
// NOT reimplement OPNsense/Proxmox logic — it authors zones.json (via zones.ts)
// and orchestrates the plane controllers (via reconcile.ts / PlaneClient).
//
//   add    : author zones.json entry + mgmt.access-to invariant → reconcile
//            ALL planes (apply).
//   delete : remove mgmt.access-to → set Disabled → reconcile ALL planes
//            (apply, so OPNsense drops the iface and Proxmox the trunk) →
//            delete the key + persist.
//
// THE #372/#373 FIX: zone-controller.sh reconciled only opnsense + proxmox on
// add/delete (it NEVER called switch-manager or ap-manager), so a new VLAN
// never reached the physical switch and off-firewall-node VMs got no IP. Here
// the lifecycle reconciles EVERY plane in dependency order — the switch (and
// ap) plane is ALWAYS included.

import { reconcileAll } from "./reconcile";
import { PlaneClient, ReconcileReport, Zone } from "./types";
import {
  AddZoneOpts,
  authorZone,
  loadZones,
  removeZone,
  saveZones,
  setZoneState,
} from "./zones";

export interface LifecycleResult {
  zone: string;
  vlantag?: number;
  report: ReconcileReport; // the all-plane reconcile outcome (empty if dryRun)
  dryRun: boolean;
}

export interface AddOpts extends AddZoneOpts {
  dryRun?: boolean;
  noActivate?: boolean; // author zones.json only; skip reconcile
}

// Create a zone end to end. Authors the zones.json entry, then reconciles EVERY
// plane (the #372/#373 fix — switch always included).
export function addZone(
  client: PlaneClient,
  zonesFile: string,
  name: string,
  opts: AddOpts,
): LifecycleResult {
  const doc = loadZones(zonesFile);
  // Author in memory first so --check / dry-run mutates nothing on disk.
  const zone: Zone = authorZone(doc, name, opts);

  if (opts.dryRun) {
    return { zone: name, vlantag: zone.vlantag, report: emptyReport(false), dryRun: true };
  }

  // Persist the authored entry (+ mgmt.access-to invariant) atomically.
  saveZones(zonesFile, doc);

  if (opts.noActivate) {
    return { zone: name, vlantag: zone.vlantag, report: emptyReport(true), dryRun: false };
  }

  // Reconcile ALL planes in dependency order (opnsense → proxmox → switch → ap).
  const report = reconcileAll(client, { apply: true, zonesFile });
  return { zone: name, vlantag: zone.vlantag, report, dryRun: false };
}

export interface DeleteOpts {
  dryRun?: boolean;
}

// Delete a zone end to end. Disables it, reconciles ALL planes (so OPNsense
// drops the interface and Proxmox the trunk; switch + ap always included), then
// removes the key + persists.
export function deleteZone(
  client: PlaneClient,
  zonesFile: string,
  name: string,
  opts: DeleteOpts,
): LifecycleResult {
  const doc = loadZones(zonesFile);
  const existing = doc.zones.get(name);
  if (!existing) throw new Error(`Zone '${name}' not found`);
  const vt = typeof existing.vlantag === "number" ? existing.vlantag : undefined;

  if (opts.dryRun) {
    return { zone: name, vlantag: vt, report: emptyReport(false), dryRun: true };
  }

  // 1. mgmt invariant + disable so the reconcile tears down the OPNsense iface.
  setZoneState(doc, name, "Disabled");
  // (removeMgmtAccess happens with removeZone below; disable first so the
  // reconcile of the still-present-but-Disabled zone drops its resources.)
  saveZones(zonesFile, doc);

  // 2. reconcile ALL planes (apply) — drops OPNsense iface + Proxmox trunk;
  //    switch + ap always included (the #372/#373 fix).
  const report = reconcileAll(client, { apply: true, zonesFile });

  // 3. remove the key (+ mgmt.access-to) and persist.
  removeZone(doc, name);
  saveZones(zonesFile, doc);

  return { zone: name, vlantag: vt, report, dryRun: false };
}

function emptyReport(apply: boolean): ReconcileReport {
  return { apply, results: [], failed: [] };
}
