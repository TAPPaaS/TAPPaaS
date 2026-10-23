// show.test.ts — `site show` prints what site.json records. The primary
// location's place is what an off-site backup copy is compared with (#609), so
// a site that records it must see it; and the location verbs (ADR-036 D1).

import { run } from "../../src/main";
import { FakeSiteClient } from "./fake-client";
import { mkdtempSync, readFileSync, writeFileSync } from "fs";
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

function capture(f: () => unknown): string[] {
  const out: string[] = [];
  const log = console.log;
  const err = console.error;
  console.log = (m: string) => void out.push(String(m));
  console.error = (m: string) => void out.push(String(m));
  try {
    f();
  } finally {
    console.log = log;
    console.error = err;
  }
  return out;
}

function cfgWith(site: Record<string, unknown>, files: Record<string, unknown> = {}): string {
  const cfg = mkdtempSync(join(tmpdir(), "show-"));
  writeFileSync(join(cfg, "site.json"), JSON.stringify({ name: "t", ...site }));
  for (const [f, v] of Object.entries(files)) writeFileSync(join(cfg, f), JSON.stringify(v));
  return cfg;
}

function show(site: Record<string, unknown>): string[] {
  const cfg = cfgWith(site);
  return capture(() => run(["site", "show", "--config-dir", cfg], new FakeSiteClient()));
}

const SITE = {
  locations: {
    rodovre: { displayName: "Rødovre", country: "DK", city: "Rodovre", address: "Rack 2", timezone: "Europe/Copenhagen" },
    hareskov: { kind: "remote", country: "DK", city: "Hareskov" },
  },
  primaryLocation: "rodovre",
  locale: "en_US",
  keyboard: "dk",
};

{
  const out = show(SITE);
  check(out.some((l) => l.includes("Location") && l.includes("rodovre (Rødovre) — Rack 2, Rodovre, DK · Europe/Copenhagen")), `site show prints the primary location (got ${out.join(" | ")})`);
  check(out.some((l) => l.includes("Locale") && l.includes("en_US · keyboard dk")), "…the locale and keyboard");
  check(out.some((l) => l.includes("Locations") && l.includes("hareskov (remote)")), "…and the others by name");
}
{
  // A site.json migration 0019 has not reached reads as the location it becomes.
  const out = show({ location: { country: "DK", timezone: "Europe/Copenhagen", city: "Copenhagen", keyboard: "dk" } });
  check(out.some((l) => l.includes("Location") && l.includes("copenhagen (Copenhagen) — Copenhagen, DK · Europe/Copenhagen")), `a pre-0019 site shows its location (got ${out.join(" | ")})`);
  check(out.some((l) => l.includes("keyboard dk")) && !out.some((l) => l.includes("Locations")), "…its keyboard, and no other locations");
}

// ── the location verbs ─────────────────────────────────────────────────
const sm = (cfg: string, ...a: string[]): { rc: number; out: string[] } => {
  let rc = 0;
  const out = capture(() => (rc = run([...a, "--config-dir", cfg], new FakeSiteClient())));
  return { rc, out };
};
const siteOf = (cfg: string): Record<string, unknown> => JSON.parse(readFileSync(join(cfg, "site.json"), "utf8")) as Record<string, unknown>;
const locs = (cfg: string): Record<string, Record<string, unknown>> => siteOf(cfg).locations as Record<string, Record<string, unknown>>;
{
  const cfg = cfgWith(SITE, { "remote-rasmus.json": { authId: "r@pbs", location: "hareskov" } });
  const l = sm(cfg, "location", "list");
  check(l.rc === 0 && l.out[0].startsWith("rodovre *") && l.out.some((x) => x.startsWith("hareskov") && x.includes("remote")), `location list: the primary first, marked (${l.out.join(" | ")})`);
  const j = JSON.parse(sm(cfg, "location", "show", "hareskov", "--json").out.join("\n")) as Record<string, unknown>;
  check(j.primary === false && JSON.stringify(j.namedBy) === '["remote-rasmus.json"]' && j.city === "Hareskov", "location show --json: the fields, primary, and what names it");

  const before = readFileSync(join(cfg, "site.json"), "utf8");
  const c = sm(cfg, "location", "add", "hetzner-fsn1", "--country", "de", "--city", "Falkenstein", "--address", "Hetzner FSN1-DC14", "--check");
  check(c.rc === 0 && c.out.some((x) => x.includes("[check] would add location 'hetzner-fsn1'")) && readFileSync(join(cfg, "site.json"), "utf8") === before, "add --check says what it would do and writes nothing");
  check(sm(cfg, "location", "add", "hetzner-fsn1", "--country", "de", "--city", "Falkenstein", "--address", "Hetzner FSN1-DC14").rc === 0 && locs(cfg)["hetzner-fsn1"].country === "DE", "add writes the location");
  check(siteOf(cfg).primaryLocation === "rodovre", "…and leaves the primary where it is");
  check(sm(cfg, "location", "add", "Bad Name", "--country", "DK").rc !== 0, "add refuses a name that is not one");
  check(sm(cfg, "location", "add", "x", "--city", "Y").rc !== 0, "add refuses a location without a country");

  check(sm(cfg, "location", "modify", "hetzner-fsn1", "--timezone", "Europe/Berlin", "--address", "").rc === 0
    && locs(cfg)["hetzner-fsn1"].timezone === "Europe/Berlin" && locs(cfg)["hetzner-fsn1"].address === undefined, "modify sets a field, and '' clears one");
  check(sm(cfg, "location", "modify", "hetzner-fsn1", "--unset", "timezone,city").rc === 0 && locs(cfg)["hetzner-fsn1"].city === undefined, "--unset clears a list of them");
  check(sm(cfg, "location", "modify", "rodovre", "--unset", "timezone").rc !== 0, "the primary keeps its timezone");

  check(sm(cfg, "location", "delete", "hareskov").out.some((x) => x.includes("named by remote-rasmus.json")) && "hareskov" in locs(cfg), "delete refuses a location a peer names");
  check(sm(cfg, "location", "delete", "rodovre").rc !== 0 && "rodovre" in locs(cfg), "…and the primary one");
  check(sm(cfg, "location", "delete", "hetzner-fsn1", "--check").rc === 0 && "hetzner-fsn1" in locs(cfg), "delete --check writes nothing");
  check(sm(cfg, "location", "delete", "hetzner-fsn1").rc === 0 && !("hetzner-fsn1" in locs(cfg)), "delete removes an unnamed location");

  check(sm(cfg, "site", "modify", "--primaryLocation", "hareskov").rc !== 0, "site modify refuses a primary without a timezone");
  check(sm(cfg, "site", "modify", "--primaryLocation", "nowhere").rc !== 0, "…and one that is no location");
  sm(cfg, "location", "modify", "hareskov", "--timezone", "Europe/Copenhagen");
  check(sm(cfg, "site", "modify", "--primaryLocation", "hareskov", "--keyboard", "us").rc === 0 && siteOf(cfg).primaryLocation === "hareskov" && siteOf(cfg).keyboard === "us", "…and takes one that has it, with the keyboard");
  check(sm(cfg, "site", "modify", "--locationCity", "Hillerød").rc === 0 && locs(cfg).hareskov.city === "Hillerød", "the retired --locationCity reaches the primary location");
}
{
  // Before migration 0019 the retired flags still write the retired shape, and the verbs wait.
  const cfg = cfgWith({ location: { country: "DK", timezone: "UTC" } });
  check(sm(cfg, "site", "modify", "--locationTimezone", "Europe/Copenhagen", "--keyboard", "dk").rc === 0
    && JSON.stringify(siteOf(cfg).location) === '{"country":"DK","timezone":"Europe/Copenhagen","keyboard":"dk"}', "a pre-0019 site.json is modified in its own shape");
  check(sm(cfg, "location", "add", "x", "--country", "DK").out.some((x) => x.includes("migration 0019")), "location add waits for the migration");
}

console.log(`show.test: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
