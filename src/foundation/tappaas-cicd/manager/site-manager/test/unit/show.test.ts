// show.test.ts — `site show` prints what site.json records. The place (city,
// building) is what an off-site backup copy is compared with (#609), so a site
// that records it must see it.

import { run } from "../../src/main";
import { FakeSiteClient } from "./fake-client";
import { mkdtempSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`  FAIL: ${msg}`);
  }
}

function show(location: Record<string, unknown>): string[] {
  const cfg = mkdtempSync(join(tmpdir(), "show-"));
  writeFileSync(join(cfg, "site.json"), JSON.stringify({ name: "t", location }));
  const out: string[] = [];
  const log = console.log;
  console.log = (m: string) => void out.push(String(m));
  try {
    run(["site", "show", "--config-dir", cfg], new FakeSiteClient());
  } finally {
    console.log = log;
  }
  return out;
}

{
  const out = show({ country: "DK", timezone: "Europe/Copenhagen", city: "Copenhagen", building: "Rack 2" });
  check(out.some((l) => l.includes("Place") && l.includes("Rack 2, Copenhagen, DK")), `site show prints the place (got ${out.join(" | ")})`);
  check(out.some((l) => l.includes("Location") && l.includes("DK / Europe/Copenhagen")), "…next to the location line");
}
{
  const out = show({ country: "DK", timezone: "Europe/Copenhagen" });
  check(!out.some((l) => l.includes("Place")), "no city or building: no Place line");
}

console.log(`show.test: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
