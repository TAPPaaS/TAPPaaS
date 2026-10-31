// assess-cmdb.test.ts — `assess` with the CMDB away: a restarting cmdb-controller
// fails no unit. Unavailable on the read or on the write, assess writes nothing
// and exits 0, as emit does; a refusal (a reporter's bug) still throws.

import { AssessIO } from "../../src/assess";
import { cmdAssess, parseOpts } from "../../src/main";
import { CmdbRefused, CmdbUnavailable } from "../../../../lib/ts/src/cmdb";
import { StubIO, obj } from "./assess-fixture";
import { FakeClusterClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(c: boolean, name: string): void {
  if (c) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

// test.sh turns the CMDB off for every verb; this suite needs it "on", stubbed.
delete process.env.TAPPAAS_CMDB;
const client = new FakeClusterClient();
const run = (io: AssessIO, ...args: string[]): number => cmdAssess(parseOpts(args), client, () => io);
const items = () => [obj("site", "home"), obj("vm", "nextcloud")];

const down = new StubIO(items());
down.objects = () => { throw new CmdbUnavailable("connect to /run/cmdb/cmdb.sock failed"); };
check(run(down) === 0, "the CMDB down on the read: exit 0");
check(down.written.length === 0, "  and nothing written");

const gone = new StubIO(items());
gone.write = () => { throw new CmdbUnavailable("HTTP 503"); };
check(run(gone) === 0, "the CMDB gone before the write: exit 0");

const json = new StubIO(items());
json.relations = () => { throw new CmdbUnavailable("HTTP 502"); };
check(run(json, "--json") === 0, "--json too");

const up = new StubIO(items());
check(run(up) === 0 && up.written.length === 1, "the CMDB up: written, exit 0");

const refused = new StubIO(items());
refused.write = () => { throw new CmdbRefused(400, { error: "no such field" }); };
let threw = false;
try { run(refused); } catch (e) { threw = e instanceof CmdbRefused; }
check(threw, "a refusal is no outage: it still throws");

console.log(`\nResults: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
