// access.test.ts — who reaches the console and as whom (ADR-034 D2, D3, D10;
// Testing T1 and T6): the connection filter, the gate's headers believed only
// from the firewall, the role table and the route cap, and the setup token,
// good only while identity is not installed.

import { mkdtempSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { AccessConfig, Me, addrMatches, decide, mayWrite, peerAllowed, presentedToken, roleOf, routeHost, setupState, splitGroups } from "../../src/access";
import { zoneGateway } from "../../src/main";
import { check, done } from "./check";
import { NOW, TEST_KEY, claimsFor, gateHeaders, signToken, testGate } from "./gate-fixture";

const dir = mkdtempSync(join(tmpdir(), "console-access-"));
const cfg: AccessConfig = {
  firewall: ["10.0.0.1"],
  allow: ["127.0.0.1", "::1"],
  setupAllow: ["10.0.0.0/24", "10.255.1.0/24"],
  tokenFile: join(dir, "console-setup-token"),
  identityFile: join(dir, "identity.json"),
  trustLocalHeaders: false,
  gate: testGate(),
};
const H = (h: Record<string, string>): Record<string, string> => ({ host: "console.hrossen.dk", ...h });
const gate = (groups: string, host = "console.hrossen.dk") => H(gateHeaders("lars", groups, host));

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
check(d.ok && d.me.role === "read" && d.me.route === "status", "the status route caps Installer at read (Host, as with proxyPreserveHost)");
// Caddy's real headers: Host is the upstream's name, the client's Host travels in X-Forwarded-Host.
const caddy = (fwdHost: string, groups = "Installer") => ({
  host: "tappaas-cicd.mgmt.internal:9097",
  "x-forwarded-host": fwdHost,
  "x-forwarded-proto": "https",
  "x-forwarded-for": "10.2.0.20",
  "x-authentik-username": "lars",
  "x-authentik-groups": groups,
  "x-authentik-jwt": gateHeaders("lars", groups)["x-authentik-jwt"],
});
d = decide("10.0.0.1", caddy("status.hrossen.dk"), null, cfg, s);
check(d.ok && d.me.route === "status" && d.me.role === "read", "through Caddy, X-Forwarded-Host names the route: status caps at read");
d = decide("10.0.0.1", caddy("console.hrossen.dk"), null, cfg, s);
check(d.ok && d.me.route === "console" && d.me.role === "installer", "…and console.<domain> operates");
d = decide("10.0.0.1", caddy("status.hrossen.dk, other.example"), null, cfg, s);
check(d.ok && d.me.route === "status", "a forwarded list: the first host is the client's");
d = decide("10.0.0.1", { ...caddy("console.hrossen.dk"), host: "console.hrossen.dk", "x-forwarded-host": "" }, null, cfg, s);
check(d.ok && d.me.route === "console" && routeHost({ host: "status.x", "x-forwarded-host": " " }, true) === "status.x", "an empty X-Forwarded-Host falls back to Host");
check(routeHost({ host: "console.hrossen.dk", "x-forwarded-host": "status.hrossen.dk" }, false) === "console.hrossen.dk", "from a peer whose headers are not believed, X-Forwarded-Host is ignored");
d = decide("127.0.0.1", gate("Installer"), null, cfg, s);
check(d.ok && d.me.via === "local" && d.me.user === null && d.me.role === "read", "headers from loopback are not believed");
d = decide("127.0.0.1", gate("Installer"), null, { ...cfg, trustLocalHeaders: true }, s);
check(d.ok && d.me.via === "gate" && d.me.role === "installer", "…unless the developer asks for it");
d = decide("127.0.0.1", caddy("status.hrossen.dk"), null, cfg, s);
check(d.ok && d.me.via === "local" && d.me.route === "console", "loopback's X-Forwarded-Host is not believed either (the dev port-forward)");
d = decide("127.0.0.1", caddy("status.hrossen.dk"), null, { ...cfg, trustLocalHeaders: true }, s);
check(d.ok && d.me.via === "gate" && d.me.route === "status", "…unless the developer asks for it (the gate proxy of a dev run)");
check(splitGroups("a| b |") .join(",") === "a,b" && roleOf(["ADMIN"]) === "admin", "groups are pipe-separated, compared without case");

// ── the gate's token: the firewall's address is not proof on its own ──
const forged = H({ "x-authentik-username": "lars", "x-authentik-groups": "installer" });
d = decide("10.0.0.1", forged, null, cfg, s);
check(!d.ok && d.status === 401 && /X-Authentik-Jwt/.test(d.reason), "from the firewall's address, the groups header without a token: 401");
const withJwt = (jwt: string) => H({ "x-authentik-username": "lars", "x-authentik-groups": "installer", "x-authentik-jwt": jwt });
d = decide("10.0.0.1", withJwt(signToken(claimsFor("lars", ["users"]))), null, cfg, s);
check(d.ok && d.me.role === "read" && d.me.groups.join() === "users", "the token's groups count, not the header's (header installer, token users: read)");
d = decide("10.0.0.1", withJwt(signToken(claimsFor("lars", ["installer"]), "another-secret")), null, cfg, s);
check(!d.ok && d.status === 401 && /signature/.test(d.reason) && d.forget === "console.hrossen.dk", "a token signed with another key: 401, and the cached key is fetched again");
d = decide("10.0.0.1", withJwt(signToken(claimsFor("lars", ["installer"]), TEST_KEY.secret, "none")), null, cfg, s);
check(!d.ok && /not HS256/.test(d.reason), "alg none (or anything but HS256): 401");
d = decide("10.0.0.1", withJwt(signToken(claimsFor("lars", ["installer"], { exp: NOW - 3600 }))), null, cfg, s);
check(!d.ok && /expired/.test(d.reason), "an expired token: 401");
d = decide("10.0.0.1", withJwt(signToken(claimsFor("lars", ["installer"], { aud: "woodpecker-client-id" }))), null, cfg, s);
check(!d.ok && /another application/.test(d.reason), "another provider's audience: 401");
d = decide("10.0.0.1", withJwt(signToken(claimsFor("lars", ["installer"], { iss: "https://identity.hrossen.dk/application/o/woodpecker/" }))), null, cfg, s);
check(!d.ok && /issuer/.test(d.reason), "another application's issuer: 401");
d = decide("10.0.0.1", H({ ...gateHeaders("eve", "installer"), "x-authentik-username": "lars" }), null, cfg, s);
check(!d.ok && /not the token's user/.test(d.reason), "a username header that is not the token's: 401");
d = decide("10.0.0.1", withJwt("not.a-jwt"), null, cfg, s);
check(!d.ok && d.status === 401, "garbage in X-Authentik-Jwt: 401");
d = decide("10.0.0.1", gate("installer", "woodpecker.hrossen.dk"), null, cfg, s);
check(!d.ok && d.status === 503, "a route that is not the console's has no key here: refused");
d = decide("10.0.0.1", gate("installer"), null, { ...cfg, gate: undefined }, s);
check(!d.ok && d.status === 503, "no key cache at all: the firewall is refused, not believed");
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
check(presentedToken({ cookie: "tappaas_setup=%E0" }, null) === "%E0", "a malformed cookie is read as it is, not thrown");
d = decide("10.0.0.50", H({ cookie: "tappaas_setup=%E0" }), null, cfg, s);
check(!d.ok && d.status === 401, "…and is a wrong token: 401");

// ── identity installed: the token is refused, even with its file ─────
writeFileSync(cfg.identityFile, "{}");
s = setupState(cfg);
check(!s.active && s.tokenPresent && s.identityInstalled, "identity.json exists: setup is over although the file remains");
check(!peerAllowed("10.0.0.50", cfg, s), "a mgmt laptop is refused again");
d = decide("127.0.0.1", H({ authorization: "Bearer s3cret-token" }), null, cfg, s);
check(d.ok && d.me.via === "local", "loopback with a stale token is just loopback");
d = decide("10.0.0.1", H({ authorization: "Bearer s3cret-token" }), null, cfg, s);
check(!d.ok && d.status === 401, "through the firewall, a token instead of the gate: 401 (T6)");

// ── writes: the gate or the token, never bare loopback (T1, T6) ───────
const me = (over: Partial<Me>): Me => ({ user: "lars", name: null, email: null, groups: [], role: "admin", via: "gate", route: "console", ...over });
const closed = { active: false, identityInstalled: true, tokenPresent: false };
const open_ = { active: true, identityInstalled: false, tokenPresent: true };
check(mayWrite(me({}), closed, false).ok, "Admin through the gate writes");
check(!mayWrite(me({}), closed, true).ok, "…but not a destructive verb (T1)");
check(mayWrite(me({ role: "installer" }), closed, true).ok, "Installer runs a destructive verb");
let w = mayWrite(me({ via: "local", user: null, role: "read" }), closed, false);
check(!w.ok && w.status === 403, "loopback without the gate's headers reads only");
w = mayWrite(me({ via: "local", role: "installer" }), closed, false);
check(!w.ok, "…whatever role it would claim");
w = mayWrite(me({ role: "read" }), closed, false);
check(!w.ok && w.status === 403, "users through the gate may not write");
w = mayWrite(me({ role: "installer", route: "status" }), closed, false);
check(!w.ok && w.status === 403, "the status route never writes");
check(mayWrite(me({ via: "setup-token", user: "setup", role: "installer" }), open_, true).ok, "the setup token acts as Installer while setup is open");
w = mayWrite(me({ via: "setup-token", user: "setup", role: "installer" }), closed, false);
check(!w.ok && w.status === 401, "…and not once identity is installed (T6)");

// ── the firewall's address comes from the mgmt zone's record ──────────
check(zoneGateway("10.0.0.0/24") === "10.0.0.1", "mgmt 10.0.0.0/24: the firewall is 10.0.0.1");
check(zoneGateway("10.0.0.0/24") === zoneGateway("10.0.0.77/24"), "the first address of the network, whatever host the ip names");
check(zoneGateway("172.16.4.0/22") === "172.16.4.1" && zoneGateway(null) === null && zoneGateway("bogus") === null, "other prefixes; no network, no gateway");

rmSync(dir, { recursive: true, force: true });
done("access");
