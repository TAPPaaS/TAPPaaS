// wizards.ts — what Setup's Day 2 sequences offer and run, kept pure so the
// unit tests check them over hrossen's records: which zones get a WiFi button
// and what it says, and each sequence's steps as the words, positionals and
// values operate.tsx turns into the argv (argv.ts).

import { ArgvStep, Values } from "./argv";

// A step's command before its form: the manifest verb it is, and the values it
// starts from (an option by its flag, a positional by "@<name>").
export interface StepSpec extends ArgvStep {
  verb: string;
  initial: Values;
}

// ── WiFi: one SSID per client zone ────────────────────────────────────

// zones.json as the zones read passes it on (network-manager's zones).
export interface ZoneIn {
  name: string;
  type?: string;
  state?: string;
  vlantag?: number;
  SSID?: string | null;
}
// `ap-manager list --json`.
export interface ApSsid {
  name: string;
  zone?: string | null;
  vlan?: number | null;
  security?: string | null;
  enabled?: boolean;
}
export interface ApIn {
  name: string;
  vendor?: string | null;
  model?: string | null;
  managementIp?: string | null;
  ssids?: ApSsid[];
}

export const WIFI_ZONE_TYPES = ["Client", "Guest"];

// The template ships every SSID as a placeholder to replace (<HOME_SSID>):
// never chosen, so not a name to broadcast or default to (wlan-lib.sh).
export const isPlaceholderSsid = (s: string): boolean => /^<.*>$/.test(s);

// A zone with no state is Active (wlan-lib.sh); Inactive and Disabled keep
// their SSID for later and broadcast nothing.
export const isActiveZone = (z: ZoneIn): boolean => (z.state ?? "Active") === "Active";

export interface WifiZone {
  zone: string;
  type: string;
  vlan: number | null;
  declared: string | null; // zones.json's SSID, when it is a real name
  ssids: { ap: string; name: string; security: string | null; enabled: boolean }[]; // what the APs map to the zone
}

// The zones a WiFi button is offered for: every active Client and Guest zone,
// in VLAN order, with the SSIDs the access points already map to it.
export function wifiZones(zones: ZoneIn[], aps: ApIn[]): WifiZone[] {
  return zones
    .filter((z) => WIFI_ZONE_TYPES.includes(z.type ?? "") && isActiveZone(z))
    .map((z) => ({
      zone: z.name,
      type: z.type!,
      vlan: typeof z.vlantag === "number" ? z.vlantag : null,
      declared: typeof z.SSID === "string" && z.SSID !== "" && !isPlaceholderSsid(z.SSID) ? z.SSID : null,
      ssids: aps.flatMap((a) => (a.ssids ?? []).filter((s) => s.zone === z.name).map((s) => ({ ap: a.name, name: s.name, security: s.security ?? null, enabled: s.enabled !== false }))),
    }))
    .sort((a, b) => (a.vlan ?? 0) - (b.vlan ?? 0) || a.zone.localeCompare(b.zone));
}

// "Change WiFi" once an access point maps an SSID to the zone, else "Add".
export const wifiVerb = (z: WifiZone): "Add" | "Change" => (z.ssids.length ? "Change" : "Add");

// The name the form starts from: the SSID the zone has, else <site>-<zone>.
export function defaultSsid(site: string, z: WifiZone): string {
  return z.ssids[0]?.name ?? z.declared ?? `${site ? `${site}-` : ""}${z.zone}`;
}

// The AP the form starts on: the one already serving the zone, else the only one.
export function defaultAp(z: WifiZone, aps: ApIn[]): string {
  return z.ssids[0]?.ap ?? (aps.length === 1 ? aps[0].name : "");
}

// A personal security mode takes a WPA passphrase (~/.wlan-secrets.txt).
export const needsPassphrase = (security: string): boolean => /-personal$/.test(security);

// An SSID's name as ap-manager and ~/.wlan-secrets.txt take it: 1–32
// characters, no '=' (the secrets file's separator), no control characters.
export function ssidProblem(name: string): string | null {
  if (!name) return "an SSID needs a name";
  if (name.length > 32) return "at most 32 characters";
  if (name.includes("=")) return "no '=' (the passphrase file is SSID=passphrase)";
  if (/[\u0000-\u001f]/.test(name)) return "no control characters";
  if (isPlaceholderSsid(name)) return "a real name, not the template's placeholder";
  return null;
}

export interface WifiPlan {
  ap: string;
  ssid: string;
  zone: string;
  vlan: number | null;
  security: string;
  replace: { ap: string; ssid: string } | null; // the SSID a change takes away
}

// The sequence: on a change, the old mapping removed; the new SSID mapped to
// the zone's VLAN; then the reconcile that programs the access points (its
// preview is the delta, apply pushes it). The passphrase is never in argv: it
// is in ~/.wlan-secrets.txt, which the plugin reads at apply.
export function wifiSpecs(p: WifiPlan): { remove: StepSpec | null; add: StepSpec; reconcile: StepSpec } {
  const add: Values = { "@ssid": p.ssid, "--zone": p.zone, "--security": p.security };
  if (p.vlan !== null) add["--vlan"] = String(p.vlan);
  return {
    remove: p.replace ? { bin: "ap-manager", verb: "ssid remove", words: ["ssid", p.replace.ap, "remove"], initial: { "@ssid": p.replace.ssid } } : null,
    add: { bin: "ap-manager", verb: "ssid add", words: ["ssid", p.ap, "add"], initial: add },
    reconcile: { bin: "ap-manager", verb: "reconcile", initial: {} },
  };
}

// ── a backup buddy: one pull through one tunnel (backup/BUDDY.md) ─────

export type BuddyKind = "pull" | "remote";

// What each side means, in one line each (BUDDY.md: the system whose data is
// pulled serves the tunnel; the pulling system dials it).
export const BUDDY_KINDS: Record<BuddyKind, string> = {
  pull: "this site pulls the buddy's backups and keeps the copy: it dials the buddy's tunnel and needs no public address",
  remote: "the buddy pulls this site's backups: this site serves the tunnel and grants the buddy a read-only login",
};

// The options each kind's form offers (peer add's own, from its manifest);
// --propagate and --force stay with the CLI. --config-only starts ticked:
// onboarding prompts for a credential on a terminal, which a job has not.
const BUDDY_OPTIONS: Record<BuddyKind, string[]> = {
  pull: ["--host", "--contact", "--tunnel", "--endpoint", "--peer-key", "--tunnel-net", "--namespace", "--remote-namespace", "--store", "--port", "--schedule", "--country", "--city", "--building", "--mtu", "--config-only"],
  remote: ["--contact", "--tunnel", "--listen-port", "--peer-key", "--tunnel-net", "--auth-id", "--namespace", "--country", "--city", "--building", "--mtu", "--config-only"],
};

// A buddy's name, as peer add accepts it.
export function buddyNameProblem(name: string): string | null {
  if (!name) return "the buddy needs a name";
  if (!/^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(name)) return "letters, digits, '-' and '_', starting with a letter or digit";
  return null;
}

// peer add <kind> <name>, its tunnel side preset (a pull dials, a remote
// serves) and --config-only ticked, then peer check <kind> <name> as the result.
export function buddySpecs(kind: BuddyKind, name: string): { add: StepSpec & { only: string[] }; check: StepSpec } {
  return {
    add: { bin: "backup-manager", verb: "peer add", words: ["peer", "add", kind], fixed: [name], only: BUDDY_OPTIONS[kind], initial: { "--tunnel": kind === "pull" ? "dial" : "serve", "--config-only": true } },
    check: { bin: "backup-manager", verb: "peer check", words: ["peer", "check", kind], fixed: [name], initial: {} },
  };
}

// ── a satellite: a public IPv4 for a site without one (satellite/INSTALL.md) ─

export const SATELLITE_ROLES: Record<string, string> = {
  "reverse-proxy": "public HTTPS ingress: :443 and :80 passed through to Caddy at home",
  "admin-vpn": "the relay for the admin VPN, so devices reach the site from anywhere",
};

export interface SatellitePlan {
  address: string; // its public IPv4
  environment: string;
  roles: string[];
  country: string; // ISO code: the evidence a backup copy on it is off-site
  city: string;
  instance: string; // empty: "satellite"; a second one needs its own name
}

const IPV4 = /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/;
// Addresses no VPS answers on from the internet.
const PRIVATE = [/^10\./, /^127\./, /^0\./, /^169\.254\./, /^192\.168\./, /^172\.(1[6-9]|2\d|3[01])\./, /^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./, /^(22[4-9]|2[3-5]\d)\./];

export function satelliteProblems(p: SatellitePlan): Record<string, string> {
  const out: Record<string, string> = {};
  if (!IPV4.test(p.address)) out.address = "its public IPv4, e.g. 203.0.113.7";
  else if (PRIVATE.some((r) => r.test(p.address))) out.address = "a private or reserved address: a satellite needs one the internet reaches";
  if (!p.environment) out.environment = "the environment it belongs to";
  if (p.roles.length === 0) out.roles = "at least one role";
  if (p.roles.some((r) => !(r in SATELLITE_ROLES))) out.roles = "reverse-proxy and/or admin-vpn";
  if (p.country && !/^[A-Z]{2}$/.test(p.country)) out.country = "an ISO country code, e.g. FI";
  if (p.instance && !/^[a-z][a-z0-9-]{0,30}$/.test(p.instance)) out.instance = "lower-case letters, digits and '-', e.g. satellite-hel1";
  return out;
}

// module-manager add satellite: --environment, --instance, and the config
// fields INSTALL.md gives (an open verb's further options, one per line).
export function satelliteSpec(p: SatellitePlan): StepSpec {
  const extra = [`--address ${p.address}`, `--roles ${JSON.stringify(p.roles)}`];
  const loc: Record<string, string> = {};
  if (p.country) loc.country = p.country;
  if (p.city) loc.city = p.city;
  if (Object.keys(loc).length) extra.push(`--physicalLocation ${JSON.stringify(loc)}`);
  const initial: Values = { "--environment": p.environment, "@extra": extra };
  if (p.instance) initial["--instance"] = p.instance;
  return { bin: "module-manager", verb: "add", fixed: ["satellite"], initial };
}

// ── an identity object: staged, then reconciled (Identity's own flow) ─

// identity-manager <kind> <verb> [<name>] --no-reconcile: config/identities
// only, so the reconcile after it is the preview of what reaches Authentik.
export function identitySpecs(kind: string, verb: "add" | "modify" | "delete", name?: string): { change: StepSpec; reconcile: StepSpec } {
  return {
    change: { bin: "identity-manager", verb: `<kind> ${verb}`, words: [kind, verb], fixed: name ? [name] : [], initial: { "--no-reconcile": true } },
    reconcile: { bin: "identity-manager", verb: "reconcile", initial: {} },
  };
}
