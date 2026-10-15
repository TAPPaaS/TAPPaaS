// timezone.test.ts — the site-timezone gate (#837): site.json's timezone
// against what the nodes and the guests run, and the fix each row names.

import { mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { checkSiteTimezone } from "../../src/checks";
import { FakeClusterClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

function configDir(site: Record<string, unknown>, modules: Record<string, Record<string, unknown>>): string {
  const dir = mkdtempSync(join(tmpdir(), "hm-tz-"));
  writeFileSync(join(dir, "site.json"), JSON.stringify(site));
  for (const [name, cfg] of Object.entries(modules)) writeFileSync(join(dir, `${name}.json`), JSON.stringify(cfg));
  return dir;
}

const site = { name: "s", location: { country: "DK", timezone: "Europe/Copenhagen" } };
const mods = {
  nextcloud: { vmid: 340, vmname: "nextcloud", zone0: "rossen" },
  gone: { vmid: 999, vmname: "gone", zone0: "rossen", status: "archived" },
};

{
  const c = new FakeClusterClient();
  c.nodes = ["tappaas1", "tappaas3"];
  c.zones.set("tappaas1", "Europe/Copenhagen");
  c.zones.set("tappaas3", "Europe/Amsterdam");
  c.zones.set("nextcloud.rossen.internal", "Europe/Copenhagen");
  c.zones.set("gone.rossen.internal", "UTC");
  const r = checkSiteTimezone(c, configDir(site, mods), "tappaas1");
  check(r.status === "warn", "a node on another zone warns");
  check(r.rows?.length === 1 && r.rows[0].text.includes("node tappaas3") && r.rows[0].text.includes("next cluster update sets Europe/Copenhagen"),
    `the node is named with the command that fixes it (got: ${r.rows?.map((x) => x.text).join(" | ")})`);
  check(r.detail.includes("site modify --locationTimezone"), "…and the way to fix the site instead");
}
{
  const c = new FakeClusterClient();
  c.zones.set("tappaas1", "Europe/Copenhagen");
  c.zones.set("nextcloud.rossen.internal", "UTC");
  const r = checkSiteTimezone(c, configDir(site, mods), "tappaas1");
  check(r.status === "warn" && !!r.rows?.[0].text.startsWith("nextcloud") && !!r.rows?.[0].text.includes("next update"),
    "a guest on another zone warns, saying its next update fixes it");
}
{
  const c = new FakeClusterClient();
  c.zones.set("tappaas1", "Europe/Copenhagen");
  c.zones.set("nextcloud.rossen.internal", "Europe/Copenhagen");
  const r = checkSiteTimezone(c, configDir(site, mods), "tappaas1");
  check(r.status === "pass" && r.detail.includes("2 node(s)/guest(s)"), `all on the site's zone pass (got: ${r.detail})`);
}
{
  const c = new FakeClusterClient();
  const r = checkSiteTimezone(c, configDir({ name: "s" }, mods), "tappaas1");
  check(r.status === "warn" && r.detail.includes("no location.timezone"), "a site.json without a timezone warns");
  const r2 = checkSiteTimezone(c, configDir(site, mods), "tappaas1");
  check(r2.status === "skip", "nothing answered: skip, never pass");
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
