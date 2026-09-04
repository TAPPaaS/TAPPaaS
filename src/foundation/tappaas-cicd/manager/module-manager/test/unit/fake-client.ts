// fake-client.ts — in-memory ModuleClient for offline unit tests.
//
// Records every lifecycle invocation (verb + module + the option flags it would
// forward to the bash script) so tests can assert exactly what `module add` /
// `delete` / etc. would shell out to, WITHOUT running any script or touching the
// cluster. Mirrors people-manager's FakeClient pattern. The configurable `rc`
// lets a test simulate a script failure.

import {
  AddOptions,
  DeleteOptions,
  InspectOptions,
  ModifyOptions,
  ModuleClient,
  ReconcileOptions,
  RunningGuest,
  SnapshotAction,
  TestOptions,
  MigrateOptions,
} from "../../src/types";

export interface Invocation {
  verb: "add" | "modify" | "delete" | "reconcile" | "inspect" | "test" | "snapshot" | "migrate";
  module: string;
  // The forwarded options, captured for assertions (for `inspect` that is the
  // dependency-service check decision, #458).
  opts?:
    | AddOptions
    | ModifyOptions
    | DeleteOptions
    | InspectOptions
    | ReconcileOptions
    | TestOptions
    | SnapshotAction;
}

export class FakeModuleClient implements ModuleClient {
  log: Invocation[] = [];
  rc = 0; // exit code every method returns (set per-test to simulate failure)
  // Live cluster state the default `list` folds in. Default [] = "cluster
  // unreachable" (the config-only graceful-degrade path); a test sets it to
  // exercise the running-vs-config merge + orphan detection.
  guests: RunningGuest[] = [];

  add(module: string, opts: AddOptions): number {
    this.log.push({ verb: "add", module, opts });
    return this.rc;
  }
  modify(module: string, opts: ModifyOptions): number {
    this.log.push({ verb: "modify", module, opts });
    return this.rc;
  }
  delete(module: string, opts: DeleteOptions): number {
    this.log.push({ verb: "delete", module, opts });
    return this.rc;
  }
  reconcile(module: string, opts: ReconcileOptions): number {
    this.log.push({ verb: "reconcile", module, opts });
    return this.rc;
  }
  inspect(module: string, opts: InspectOptions = {}): number {
    this.log.push({ verb: "inspect", module, opts });
    return this.rc;
  }
  test(module: string, opts: TestOptions): number {
    this.log.push({ verb: "test", module, opts });
    return this.rc;
  }
  migrate(module: string, opts: MigrateOptions): number {
    this.log.push({ verb: "migrate", module, opts });
    return this.rc;
  }
  snapshot(module: string, action: SnapshotAction): number {
    this.log.push({ verb: "snapshot", module, opts: action });
    return this.rc;
  }
  clusterResources(): RunningGuest[] {
    return this.guests;
  }
}
