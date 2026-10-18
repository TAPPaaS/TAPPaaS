// setup.ts — the Setup wizard's checklist (ADR-034 D10, spike §5.12). Its
// state is derived from the records every time, never stored, so the wizard
// resumes for free: setupSteps() is a pure function of what the records say;
// gatherSetup() reads them (config files, the managers, lib/ts cluster.ts for
// membership). Each step is then a form over its verbs in the front end, run
// as jobs with their previews.
//
//   tls        wildcard mode: config/cert-refids.json names the default
//              environment (acme-setup.sh recorded the certificate);
//              per-service mode: nothing to issue — Caddy gets each route's
//              certificate itself (HTTP-01)
//   backup, identity, logging   config/<module>.json exists and its module
//              test passes (rest-of-foundation.sh's three)
//   bootstrap  config/identities holds an organization and a user
//   nodes      every node site.json declares is a cluster member
//   switch     a switch is registered and interrogated (ports discovered)
//   vpn        the admin VPN has at least one peer (network-manager wgvpn list)
//   stacks     optional: which stacks have modules installed

import { existsSync, readdirSync, readFileSync, unlinkSync } from "fs";
import { join } from "path";
import { AccessConfig, setupState } from "./access";
import { Runner } from "./run";

export interface TestResult {
  rc: number;
  tail: string;
}

export interface SetupInputs {
  defaultEnv: string | null;
  dnsMode: "wildcard" | "per-service" | null;
  certRefids: Record<string, unknown> | null;
  modules: Record<"backup" | "identity" | "logging", { config: boolean; test: TestResult | null }>;
  identities: { organizations: number; users: number };
  siteNodes: string[];
  clusterNodes: string[] | null; // null: membership could not be read
  switches: { name: string; ports: number; discovered: number; controller: string | null }[] | null;
  vpnPeers: string[] | null; // null: wgvpn list could not be read
  stacks: string[];
}

export type StepId = "tls" | "backup" | "identity" | "logging" | "bootstrap" | "nodes" | "switch" | "vpn" | "stacks";

export interface SetupStep {
  id: StepId;
  title: string;
  required: boolean;
  done: boolean | null; // null: not known (a read failed)
  detail: string;
}

const MODULE_TITLES = { backup: "Backup (PBS)", identity: "Identity (Authentik)", logging: "Logging (Loki, Grafana)" };

export function setupSteps(i: SetupInputs): SetupStep[] {
  const steps: SetupStep[] = [];

  if (i.dnsMode === "wildcard") {
    const has = !!i.defaultEnv && !!i.certRefids && typeof i.certRefids[i.defaultEnv] === "string";
    steps.push({ id: "tls", title: "TLS — the wildcard certificate", required: true, done: has, detail: has ? `config/cert-refids.json: ${i.defaultEnv} → ${String(i.certRefids![i.defaultEnv!])}` : `no certificate recorded for ${i.defaultEnv ?? "the default environment"} in config/cert-refids.json` });
  } else {
    steps.push({ id: "tls", title: "TLS — certificates", required: true, done: i.defaultEnv !== null, detail: i.defaultEnv ? `${i.defaultEnv} is dnsMode per-service: Caddy gets each route's certificate itself (HTTP-01); there is no wildcard to issue` : "no default environment yet (site.json)" });
  }

  for (const m of ["backup", "identity", "logging"] as const) {
    const s = i.modules[m];
    const done = !s.config ? false : s.test === null ? null : s.test.rc === 0;
    const detail = !s.config ? `config/${m}.json does not exist: not installed` : s.test === null ? `installed (config/${m}.json); its test has not run yet` : s.test.rc === 0 ? `installed; module-manager test ${m} passes` : `installed; module-manager test ${m} fails (exit ${s.test.rc}): ${s.test.tail}`;
    steps.push({ id: m, title: MODULE_TITLES[m], required: true, done, detail });
  }

  const boot = i.identities.organizations > 0 && i.identities.users > 0;
  steps.push({ id: "bootstrap", title: "Identity bootstrap — your organization and you", required: true, done: boot, detail: boot ? `config/identities: ${i.identities.organizations} organization(s), ${i.identities.users} user(s)` : "config/identities has no organization or no user yet" });

  if (i.clusterNodes === null) {
    steps.push({ id: "nodes", title: "Nodes", required: true, done: null, detail: "the cluster's membership could not be read" });
  } else {
    const missing = i.siteNodes.filter((n) => !i.clusterNodes!.includes(n));
    steps.push({ id: "nodes", title: "Nodes", required: true, done: i.siteNodes.length > 0 && missing.length === 0, detail: missing.length ? `not joined: ${missing.join(", ")}` : `${i.siteNodes.length} node(s), all cluster members: ${i.siteNodes.join(", ")}` });
  }

  if (i.switches === null) {
    steps.push({ id: "switch", title: "The switch", required: true, done: null, detail: "switch-configuration-actual.json could not be read" });
  } else {
    const ok = i.switches.filter((s) => s.discovered > 0);
    steps.push({ id: "switch", title: "The switch", required: true, done: ok.length > 0, detail: i.switches.length === 0 ? "no switch registered" : ok.length ? i.switches.map((s) => `${s.name}: ${s.ports} port(s), ${s.discovered} discovered${s.controller ? ` via ${s.controller}` : ""}`).join("; ") : `registered (${i.switches.map((s) => s.name).join(", ")}) but not interrogated: no port discovered` });
  }

  if (i.vpnPeers === null) steps.push({ id: "vpn", title: "The admin VPN", required: true, done: null, detail: "network-manager wgvpn list could not be read" });
  else steps.push({ id: "vpn", title: "The admin VPN", required: true, done: i.vpnPeers.length > 0, detail: i.vpnPeers.length ? `peer(s): ${i.vpnPeers.join(", ")}` : "no peer yet: enrol a device" });

  steps.push({ id: "stacks", title: "Stacks (optional)", required: false, done: i.stacks.length > 0, detail: i.stacks.length ? `installed: ${i.stacks.join(", ")}` : "none yet" });
  return steps;
}

export function setupComplete(steps: SetupStep[]): boolean {
  return steps.every((s) => !s.required || s.done === true);
}

// ── parsing what the records say ──────────────────────────────────────

// `network-manager wgvpn list`: the rows under "peers :".
export function parseWgvpnPeers(out: string): string[] {
  const lines = out.replace(/\x1b\[[0-9;]*m/g, "").split("\n");
  const at = lines.findIndex((l) => /^peers\s*:/.test(l));
  if (at < 0) return [];
  const peers: string[] = [];
  for (const l of lines.slice(at + 1)) {
    const m = /^\s+-\s+(\S+)/.exec(l);
    if (m) peers.push(m[1]);
    else if (l.trim() && !/^\s/.test(l)) break;
  }
  return peers;
}

export function parseSwitches(doc: unknown): SetupInputs["switches"] {
  const sw = (doc as { switches?: Record<string, { controller?: string; ports?: Record<string, { source?: string }> }> })?.switches;
  if (!sw || typeof sw !== "object") return [];
  return Object.entries(sw).map(([name, s]) => {
    const ports = Object.values(s.ports ?? {});
    return { name, ports: ports.length, discovered: ports.filter((p) => p.source === "discovered").length, controller: s.controller ?? null };
  });
}

function readJson(f: string): Record<string, unknown> | null {
  try {
    return existsSync(f) ? (JSON.parse(readFileSync(f, "utf8")) as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function countJson(dir: string): number {
  try {
    return readdirSync(dir).filter((f) => f.endsWith(".json")).length;
  } catch {
    return 0;
  }
}

export interface GatherDeps {
  configDir: string;
  run: Runner;
  clusterNodes: (siteNodes: string[]) => string[] | null;
  stacks: () => Promise<string[]>;
}

export async function gatherSetup(d: GatherDeps): Promise<SetupInputs> {
  const site = readJson(join(d.configDir, "site.json")) ?? {};
  const defaultEnv = (site.defaultEnvironment as string | undefined) ?? (site.name as string | undefined) ?? null;
  const envDoc = defaultEnv ? readJson(join(d.configDir, "environments", `${defaultEnv}.json`)) : null;
  const dnsMode = ((envDoc?.domains as { dnsMode?: string } | undefined)?.dnsMode === "wildcard" ? "wildcard" : envDoc ? "per-service" : null) as SetupInputs["dnsMode"];
  const siteNodes = (((site.hardware as { nodes?: { name?: string }[] } | undefined)?.nodes ?? []).map((n) => n.name).filter((n): n is string => typeof n === "string"));
  const modules = {} as SetupInputs["modules"];
  await Promise.all(
    (["backup", "identity", "logging"] as const).map(async (m) => {
      const config = existsSync(join(d.configDir, `${m}.json`));
      let test: TestResult | null = null;
      if (config) {
        const r = await d.run("module-manager", ["test", m], 15 * 60_000);
        const tail = (r.stdout + r.stderr).replace(/\x1b\[[0-9;]*m/g, "").trim().split("\n").slice(-1)[0] ?? "";
        test = r.ran ? { rc: r.rc, tail } : null;
      }
      modules[m] = { config, test };
    }),
  );
  const idDir = join(d.configDir, existsSync(join(d.configDir, "identities")) ? "identities" : "people");
  const vpn = await d.run("network-manager", ["wgvpn", "list"], 60_000);
  return {
    defaultEnv,
    dnsMode,
    certRefids: readJson(join(d.configDir, "cert-refids.json")),
    modules,
    identities: { organizations: countJson(join(idDir, "organizations")), users: countJson(join(idDir, "users")) },
    siteNodes,
    clusterNodes: d.clusterNodes(siteNodes),
    switches: existsSync(join(d.configDir, "switch-configuration-actual.json")) ? parseSwitches(readJson(join(d.configDir, "switch-configuration-actual.json"))) : [],
    vpnPeers: vpn.ran && vpn.rc === 0 ? parseWgvpnPeers(vpn.stdout + vpn.stderr) : null,
    stacks: await d.stacks().catch(() => []),
  };
}

// The setup token closes itself (D10, T6): once identity is installed the
// token is refused, and its file is deleted here — after the identity step,
// and at any later look.
export function closeSetupToken(access: AccessConfig, log: (l: string) => void = () => undefined): boolean {
  const s = setupState(access);
  if (!(s.identityInstalled && s.tokenPresent)) return false;
  try {
    unlinkSync(access.tokenFile);
    log(`identity is installed: deleted the setup token ${access.tokenFile}`);
    return true;
  } catch (e) {
    log(`could not delete the setup token ${access.tokenFile}: ${(e as Error).message}`);
    return false;
  }
}
