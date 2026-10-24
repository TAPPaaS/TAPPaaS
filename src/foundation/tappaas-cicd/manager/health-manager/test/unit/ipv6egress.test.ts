// ipv6egress.test.ts — the ipv6-egress gate (#875) over three states: IPv6
// off, hrossen healthy (2026-10-24, after the WAN was reconfigured), and hrossen
// on 2026-10-23 (the ISP's router replaced, OPNsense still naming the old one,
// no default route, no answer from a rossen guest).

import { mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { RELEARN, Wan6, checkIpv6Egress, ipv6EgressResult, serviceV6Zones } from "../../src/ipv6egress";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const NEW = "fe80::47:ff:fe00:168";
const OLD = "fe80::ff:fe91:2291";
const HEALTHY: Wan6 = {
  wanif: "vtnet1", recorded: NEW, route: NEW, gateway: NEW, prefix: "2a13:e747:a210:4500::/56",
  address: "2a13:e740:292:978c::545", rtsold: true, routerAnswers: true,
};
const STALE: Wan6 = {
  wanif: "vtnet1", recorded: OLD, route: "", gateway: OLD, prefix: "2a13:e747:a210:8200::/56",
  address: "2a13:e740:292:978c::aba", rtsold: true, routerAnswers: false,
};

// ── off ──
{
  const r = ipv6EgressResult({ ipv6: false, wan: null, probe: null });
  check(r.status === "skip" && /off/.test(r.detail), "IPv6 off — skip");
  const dir = mkdtempSync(join(tmpdir(), "egress-"));
  writeFileSync(join(dir, "site.json"), JSON.stringify({ name: "t" }));
  check(checkIpv6Egress(dir, "tappaas1").status === "skip", "site.json without ipv6 — skip, nothing probed");
}

// ── healthy ──
{
  const r = ipv6EgressResult({ ipv6: true, wan: HEALTHY, probe: { from: "immich", to: "2606:4700:4700::1111", ok: true } });
  check(r.status === "pass", `healthy — pass (${r.detail})`);
  check(r.detail.includes(`via ${NEW}`) && r.detail.includes("answers from immich"), "the detail names the router and the guest");
  const n = ipv6EgressResult({ ipv6: true, wan: HEALTHY, probe: null });
  check(n.status === "pass" && /not probed/.test(n.detail), "firewall fine, nothing to probe from — pass, says so");
}

// ── stale (2026-10-23) ──
{
  const r = ipv6EgressResult({ ipv6: true, wan: STALE, probe: { from: "immich", to: "2606:4700:4700::1111", ok: false } });
  check(r.status === "warn", "stale router — warn");
  const fw = (r.rows ?? []).find((x) => x.subject?.kind === "module" && x.subject.name === "network");
  check(!!fw && fw.text.includes("no IPv6 default route") && fw.text.includes(OLD), "the cause: no route, the recorded router named");
  check(!!fw && fw.text.includes(RELEARN), "the finding names the re-learn verb");
  check((r.rows ?? []).some((x) => x.subject?.kind === "site" && /no public IPv6 address answered from immich/.test(x.text)), "the egress failure sits on the uplink");
  check(r.detail.startsWith("IPv6 egress fails"), "the detail says egress fails");
}
{
  // The route is there but its router is gone (before the kernel dropped it).
  const r = ipv6EgressResult({ ipv6: true, wan: { ...STALE, route: OLD }, probe: { from: "cicd", to: "x", ok: false } });
  check(r.status === "warn" && (r.rows ?? []).some((x) => x.text.includes(`router ${OLD} does not answer`)), "a route to a router that does not answer — warn");
}
{
  const r = ipv6EgressResult({ ipv6: true, wan: { ...HEALTHY, recorded: OLD }, probe: { from: "cicd", to: "x", ok: true } });
  check(r.status === "warn" && /answers but the firewall is not as recorded/.test(r.detail), "egress answers, the record differs — warn");
  const s = ipv6EgressResult({ ipv6: true, wan: { ...HEALTHY, rtsold: false }, probe: { from: "cicd", to: "x", ok: true } });
  check(s.status === "warn" && (s.rows ?? []).some((x) => /rtsold is not running/.test(x.text)), "rtsold not running — warn");
  const g = ipv6EgressResult({ ipv6: true, wan: HEALTHY, probe: { from: "immich", to: "x", ok: false, noAddress: true } });
  check(g.status === "warn" && /immich holds no global IPv6 address/.test(g.rows?.[0]?.text ?? ""), "a guest without a global address — said so");
  const u = ipv6EgressResult({ ipv6: true, wan: null, wanError: "ssh: connect timed out", probe: null });
  check(u.status === "warn" && /could not be read.*timed out/.test(u.detail), "the firewall unreadable — warn with why");
}

// ── which zones a guest may probe from ──
check(
  JSON.stringify(serviceV6Zones({
    _README: "x",
    rossen: { type: "Service", state: "Active", ipv6Subnet: 32 },
    test: { type: "Service", state: "Inactive", ipv6Subnet: 1 },
    mgmt: { type: "Management", state: "Manual" },
    dmz: { type: "DMZ", state: "Mandatory", ipv6Subnet: 97 },
    srv: { type: "Service", state: "Active" },
  })) === JSON.stringify(["rossen"]),
  "Service zones with an ipv6Subnet that are live",
);

console.log(`\nipv6-egress: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
