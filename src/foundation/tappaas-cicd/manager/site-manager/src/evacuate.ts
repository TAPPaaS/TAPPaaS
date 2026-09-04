// evacuate — clear a node for maintenance (ADR-019 scenario C).
//
// Fleet orchestration lives in site-manager, and it drives module-manager per
// module — never the controller directly. That layering is not ceremony:
// module-manager owns the module's config and the HA-rule reconciliation a move
// implies, so a controller called straight from a fleet loop would move guests
// while leaving their rules and config behind. (migrate-node.sh, which this
// supersedes, called migrate-vm.sh directly and did exactly that.)
//
// Each guest goes through `module migrate`, which realizes the module's OWN
// declared placement rather than a destination this loop picked. That covers
// the awkward case the ADR names — a guest sitting on its HANode while that
// node is the one being evacuated — because migrate reads the direction from
// where the guest currently is, and sends it back to .node.
//
// Kept apart from main.ts so it is testable without a cluster or a CLI.

import { SiteClient } from "./types";

export interface EvacuateResult {
  // Guests the cluster reported on the node (empty when it had none).
  considered: string[];
  // Moved successfully.
  moved: string[];
  // Refused for want of downtime authorization (module-manager rc 10).
  deferred: string[];
  // Failed for any other reason, as "<module> (rc N)".
  failed: string[];
  // null when the cluster could not be asked at all.
  unreachable: boolean;
}

export function evacuateNode(
  node: string,
  client: SiteClient,
  force: boolean,
): EvacuateResult {
  const r: EvacuateResult = {
    considered: [],
    moved: [],
    deferred: [],
    failed: [],
    unreachable: false,
  };

  const guests = client.guestsOn(node);
  if (guests === null) {
    r.unreachable = true;
    return r;
  }

  for (const g of guests) {
    r.considered.push(g.name);
    const rc = client.migrateModule(g.name, force);
    if (rc === 0) r.moved.push(g.name);
    else if (rc === 10) r.deferred.push(g.name);
    else r.failed.push(`${g.name} (rc ${rc})`);
  }
  return r;
}

// The exit code for a result.
//
// "Not clear" is NOT success: ADR-017's reboot pass calls this before rebooting
// a node, and reporting 0 over a half-done evacuation would reboot a node with
// guests still running on it. Deferred (downtime unauthorized) is distinct from
// failed, so a caller can tell "you need to decide" from "something broke".
export function evacuateExitCode(r: EvacuateResult): number {
  if (r.unreachable) return 1;
  if (r.failed.length > 0) return 1;
  if (r.deferred.length > 0) return 10;
  return 0;
}
