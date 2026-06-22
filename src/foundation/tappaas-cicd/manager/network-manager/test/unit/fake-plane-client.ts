// fake-plane-client.ts — in-memory PlaneClient for offline reconcile unit tests.
//
// Records every (plane, apply, zonesFile) call in order so tests can assert the
// orchestration calls all four planes in dependency order with the right
// dry-run/apply flag — and that the switch plane IS invoked on zone add (the
// #372/#373 fix). Per-plane rc is scriptable so tests can model in-sync / drift
// / error aggregation without any cluster.

import { Plane, PlaneClient, PlaneResult, PlaneStatus } from "../../src/types";

export interface RecordedCall {
  plane: Plane;
  apply: boolean;
  zonesFile: string;
}

function statusFromRc(rc: number, apply: boolean): PlaneStatus {
  if (rc === 0) return "in-sync";
  if (rc === 2) return apply ? "needs-manual" : "drift";
  return "error";
}

export class FakePlaneClient implements PlaneClient {
  calls: RecordedCall[] = [];
  // Per-plane scripted rc (default 0 = in-sync).
  rcs: Partial<Record<Plane, number>> = {};

  setRc(plane: Plane, rc: number): void {
    this.rcs[plane] = rc;
  }

  reconcile(plane: Plane, apply: boolean, zonesFile: string): PlaneResult {
    this.calls.push({ plane, apply, zonesFile });
    const rc = this.rcs[plane] ?? 0;
    const status = statusFromRc(rc, apply);
    return { plane, status, rc, message: `${plane} (fake rc=${rc})` };
  }

  // Convenience: the ordered list of planes invoked.
  planesCalled(): Plane[] {
    return this.calls.map((c) => c.plane);
  }
}
