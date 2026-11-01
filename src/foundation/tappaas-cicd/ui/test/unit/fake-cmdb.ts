// fake-cmdb.ts — the CMDB of the Health fixture site (test/fixtures/health-site.json):
// one node down with its guests impacted, one acknowledged root, one flapping
// condition, one guest in a maintenance window. `set` moves an object's
// conditions and `tell` plays the change stream, so a test sees what a report
// would do. Built by hand: health-assess writes this shape on a real site.

import { readFileSync } from "fs";
import { join } from "path";
import { FixtureCmdb, HealthSite, metamodelRelations } from "../../src/fixtures";
import { RelationType } from "../../src/health";

const FIX = process.env.CONSOLE_FIXTURES ?? "test/fixtures";

export type { HealthSite };

export function healthSite(): HealthSite {
  return JSON.parse(readFileSync(join(FIX, "health-site.json"), "utf8")) as HealthSite;
}

// The shipped metamodel's relation types, as /v1/rules serves them: the tests
// walk what a site walks.
export function relationTypes(): RelationType[] {
  return metamodelRelations(join(FIX, "..", "..", "..", "controller"));
}

export class FakeCmdb extends FixtureCmdb {
  constructor() {
    super({ ...healthSite(), relationTypes: relationTypes() });
  }
}
