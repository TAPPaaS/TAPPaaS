// version.test.ts — reading the running version from `git describe` (ADR-028 D13).

import { versionFromDescribe } from "../../src/version";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`  FAIL: ${msg}`);
  }
}

check(versionFromDescribe("v2.1-0-g83ccb498\n") === "2.1", "a checkout on a release tag is that release");
check(versionFromDescribe("v2.1-14-g83ccb498") === "2.1+14", "past a tag it says how far");
check(versionFromDescribe("v2.1.1-0-gabc1234") === "2.1.1", "an urgent fix keeps its third number");
check(versionFromDescribe("v1.0.0-3-gabc1234") === "1.0.0+3", "the old three-part tags still read");
check(versionFromDescribe("v2.0-rc1-2-gabc1234") === null, "a tag that is not a release is not a version");
check(versionFromDescribe("nixos-template-v1.4-0-gabc1234") === null, "an image tag is not a TAPPaaS version");
check(versionFromDescribe("") === null, "no describe output, no version");

console.log(`version: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
