// access.test.ts — who reaches the console and as whom (ADR-034 D2, D3, D10;
// Testing T1 and T6): the connection filter, the gate's headers believed only
// from the firewall, the role table and the route cap, and the setup token,
// good only while identity is not installed.

import { mkdtempSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { AccessConfig, addrMatches, decide, peerAllowed, presentedToken, roleOf, setupState, splitGroups } from "../../src/access";
import { check, done } from "./check";

const dir = mkdtempSync(join(tmpdir(), "console-access-"));
const cfg: AccessConfig = {
  firewall: ["10.0.0.1"],
  allow: ["127.0.0.1", "::1"],
  setupAllow: ["10.0.0.0/24", "10.255.1.0/24"],
  tokenFile: join(dir, "console-setup-token"),
  identityFile: join(dir, "identity.json"),
  trustLocalHeaders: false,
};
const H = (h: Record<string, string>): Record<string, string> => ({ host: "console.hrossen.dk", ...h });
const gate = (groups: string, host = "console.hrossen.dk") => H({ host, "x-authentik-username": "lars", "x-authentik-groups": groups });

// ── addresses ─────────────────────────────────────────────────────────
check(addrMatches("10.0.0.50", "10.0.0.0/24") && !addrMatches("10.0.1.50", "10.0.0.0/24"), "a.b.c.d/n matches its network only");
check(addrMatches("::ffff:10.0.0.1", "10.0.0.1"), "an IPv4-mapped peer is its IPv4 address");
check(!addrMatches("10.0.0.10", "10.0.0.1"), "an exact entry is exact");

// ── no setup token: firewall and loopback only ────────────────────────
let s = setupState(cfg);
check(!s.active && !s.tokenPresent, "no token file: setup is not active");
check(peerAllowed("10.0.0.1", cfg, s), "the firewall connects");
check(peerAllowed("127.0.0.1", cfg, s), "loopback connects (the dev port-forward)");
check(!peerAllowed("10.0.0.144", cfg, s), "another mgmt address is refused (T1)");
check(!peerAllowed("10.0.0.50", cfg, s), "a laptop on mgmt is refused");

// ── the gate's headers, from the firewall only ───────────────────────
let d = decide("10.0.0.1", gate("users|Admin"), null, cfg, s);
check(d.ok && d.me.user === "lars" && d.me.role === "admin" && d.me.via === "gate", "Admin through the gate operates");
d = decide("10.0.0.1", gate("Installer|users"), null, cfg, s);
check(d.ok && d.me.role === "installer", "Installer is the installer role");
d = decide("10.0.0.1", gate("users"), null, cfg, s);
check(d.ok && d.me.role === "read", "users reads");
d = decide("10.0.0.1", gate("guests"), null, cfg, s);
check(!d.ok && d.status === 403, "a user in none of the groups is refused");
d = decide("10.0.0.1", H({}), null, cfg, s);
check(!d.ok && d.status === 401, "from the firewall without the gate's headers: refused (an ungated route)");
d = decide("10.0.0.1", gate("Installer", "status.hrossen.dk"), null, cfg, s);
check(d.ok && d.me.role === "read" && d.me.route === "status", "the status route caps Installer at read");
d = decide("127.0.0.1", gate("Installer"), null, cfg, s);
check(d.ok && d.me.via === "local" && d.me.user === null && d.me.role === "read", "headers from loopback are not believed");
d = decide("127.0.0.1", gate("Installer"), null, { ...cfg, trustLocalHeaders: true }, s);
check(d.ok && d.me.via === "gate" && d.me.role === "installer", "…unless the developer asks for it");
check(splitGroups("a| b |") .join(",") === "a,b" && roleOf(["ADMIN"]) === "admin", "groups are pipe-separated, compared without case");

// ── the setup token before identity (D10, T6) ─────────────────────────
writeFileSync(cfg.tokenFile, "s3cret-token\n");
s = setupState(cfg);
check(s.active && s.tokenPresent && !s.identityInstalled, "token file and no identity.json: setup is active");
check(peerAllowed("10.0.0.50", cfg, s) && peerAllowed("10.255.1.7", cfg, s), "…mgmt and the admin VPN may connect");
check(!peerAllowed("10.2.0.20", cfg, s), "…a service zone still may not");
d = decide("10.0.0.50", H({}), null, cfg, s);
check(!d.ok && d.status === 401, "from mgmt without the token: 401");
d = decide("10.0.0.50", H({ authorization: "Bearer s3cret-token" }), null, cfg, s);
check(d.ok && d.me.via === "setup-token" && d.me.role === "installer", "with the token: the installer");
d = decide("10.0.0.50", H({}), "s3cret-token", cfg, s);
check(d.ok && d.me.via === "setup-token", "?token= works on a first page load");
d = decide("10.0.0.50", H({ cookie: "a=b; tappaas_setup=s3cret-token" }), null, cfg, s);
check(d.ok && d.me.via === "setup-token", "…and so does the cookie it becomes");
d = decide("10.0.0.50", H({ authorization: "Bearer wrong" }), null, cfg, s);
check(!d.ok && d.status === 401, "a wrong token: 401");
d = decide("10.0.0.50", gate("Installer"), null, cfg, s);
check(!d.ok, "headers from a mgmt laptop are not an identity");
check(presentedToken({ authorization: "bearer  abc " }, null) === "abc", "Bearer is read without case");

// ── identity installed: the token is refused, even with its file ─────
writeFileSync(cfg.identityFile, "{}");
s = setupState(cfg);
check(!s.active && s.tokenPresent && s.identityInstalled, "identity.json exists: setup is over although the file remains");
check(!peerAllowed("10.0.0.50", cfg, s), "a mgmt laptop is refused again");
d = decide("127.0.0.1", H({ authorization: "Bearer s3cret-token" }), null, cfg, s);
check(d.ok && d.me.via === "local", "loopback with a stale token is just loopback");
d = decide("10.0.0.1", H({ authorization: "Bearer s3cret-token" }), null, cfg, s);
check(!d.ok && d.status === 401, "through the firewall, a token instead of the gate: 401 (T6)");

rmSync(dir, { recursive: true, force: true });
done("access");
