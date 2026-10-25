// gate-fixture.ts — the identity gate as the tests meet it: a provider key for
// the console's routes and the headers the outpost sends, its HS256 token
// included (gate.ts).

import { createHmac } from "crypto";
import { GateKey, GateKeys, isConsoleHost } from "../../src/gate";

export const TEST_KEY: GateKey = { clientId: "console-client-id", secret: "console-client-secret-for-tests", slug: "console" };
export const NOW = Math.floor(Date.now() / 1000);

export function signToken(claims: Record<string, unknown>, secret = TEST_KEY.secret, alg = "HS256"): string {
  const b = (o: unknown): string => Buffer.from(JSON.stringify(o), "utf8").toString("base64url");
  const head = b({ alg, typ: "JWT" });
  const body = b(claims);
  const sig = createHmac("sha256", secret).update(`${head}.${body}`).digest().toString("base64url");
  return `${head}.${body}.${sig}`;
}

export function claimsFor(user: string, groups: string[], over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    iss: "https://identity.hrossen.dk/application/o/console/",
    aud: TEST_KEY.clientId,
    iat: NOW - 10,
    exp: NOW + 3600,
    preferred_username: user,
    groups,
    name: user,
    email: `${user}@example.org`,
    ...over,
  };
}

// What the outpost sends for `user` in `groups` ("a|b", as the header carries them).
export function gateHeaders(user: string, groups: string, host = "console.hrossen.dk"): Record<string, string> {
  const g = groups.split("|").filter((x) => x);
  return { host, "x-authentik-username": user, "x-authentik-groups": groups, "x-authentik-jwt": signToken(claimsFor(user, g)) };
}

// A key cache that already holds TEST_KEY for every console route (decide()
// reads it synchronously; server.ts warms the real one before it decides).
export function testGate(): GateKeys {
  const g = new GateKeys(async () => TEST_KEY);
  g.get = (host: string) => (isConsoleHost(host) ? TEST_KEY : null);
  return g;
}
