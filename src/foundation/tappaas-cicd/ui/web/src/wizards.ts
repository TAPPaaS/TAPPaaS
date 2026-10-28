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

// ── WiFi: one site-wide SSID per client zone (#889) ───────────────────

// zones.json as the zones read passes it on (network-manager's zones).
export interface ZoneIn {
  name: string;
  type?: string;
  state?: string;
  vlantag?: number;
  SSID?: string | null;
}
// `ap-manager list --json`: each access point and the SSIDs it broadcasts
// (written by ap-manager from the site-wide list).
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
// `ap-manager ssid list --json`: the site-wide SSIDs — each bridged to one zone,
// broadcast by the access points it names (or all), and whether its passphrase
// is set; never the passphrase.
export type PassphraseState = "set" | "changed" | "not set" | "not needed";
export interface SiteSsid {
  name: string;
  zone: string;
  vlan?: number | null;
  security: string;
  radius?: string | null;
  captive?: boolean;
  disabled?: boolean;
  broadcastOn?: "all" | string[];
  accessPoints?: string[];
  passphrase?: PassphraseState;
}

export const WIFI_ZONE_TYPES = ["Client", "Guest", "IoT"];

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
  ssid: SiteSsid | null; // the site-wide SSID that bridges to the zone
}

// The zones a WiFi button is offered for: every active Client, Guest and IoT zone,
// in VLAN order, with the site-wide SSID that bridges to it.
export function wifiZones(zones: ZoneIn[], ssids: SiteSsid[]): WifiZone[] {
  return zones
    .filter((z) => WIFI_ZONE_TYPES.includes(z.type ?? "") && isActiveZone(z))
    .map((z) => ({
      zone: z.name,
      type: z.type!,
      vlan: typeof z.vlantag === "number" ? z.vlantag : null,
      declared: typeof z.SSID === "string" && z.SSID !== "" && !isPlaceholderSsid(z.SSID) ? z.SSID : null,
      ssid: ssids.find((s) => s.zone === z.name) ?? null,
    }))
    .sort((a, b) => (a.vlan ?? 0) - (b.vlan ?? 0) || a.zone.localeCompare(b.zone));
}

// "Change WiFi" once an SSID bridges to the zone, else "Add".
export const wifiVerb = (z: WifiZone): "Add" | "Change" => (z.ssid ? "Change" : "Add");

// The name the form starts from: the SSID the zone has, else <site>-<zone>.
export function defaultSsid(site: string, z: WifiZone): string {
  return z.ssid?.name ?? z.declared ?? `${site ? `${site}-` : ""}${z.zone}`;
}

// A personal security mode takes a WPA passphrase (~/.wlan-secrets.txt).
export const needsPassphrase = (security: string): boolean => /-personal$/.test(security);

// Where an SSID is broadcast, in words.
export function broadcastText(s: SiteSsid): string {
  const on = s.accessPoints ?? [];
  if (s.disabled) return "off (declared, broadcast nowhere)";
  if ((s.broadcastOn ?? "all") === "all") return on.length ? `every access point (${on.join(", ")})` : "every access point (none registered yet)";
  return on.length ? on.join(", ") : "no access point";
}

// A passphrase state as the pages say it: set, set but not pushed yet, missing
// (a personal SSID without one cannot be created on the access point), or none
// needed (open, enterprise).
export const PASSPHRASE_TEXT: Record<PassphraseState, string> = {
  set: "set",
  changed: "changed — the next reconcile pushes it",
  "not set": "not set",
  "not needed": "none needed",
};
export const passphraseOf = (s: SiteSsid): PassphraseState => s.passphrase ?? (needsPassphrase(s.security) ? "not set" : "not needed");

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

// A WPA passphrase as ap-manager takes it: 8–63 printable characters.
export function passphraseProblem(p: string): string | null {
  if (p.length < 8 || p.length > 63) return "8 to 63 characters";
  if (!/^[\x20-\x7e]+$/.test(p)) return "printable characters only";
  return null;
}

export interface WifiPlan {
  ssid: string;
  zone: string;
  vlan: number | null;
  security: string;
  old: SiteSsid | null; // the SSID the zone has today
}

// The sequence. A new SSID: `ssid add`. Another name than the zone's SSID:
// `ssid remove` of the old one first (one SSID per zone). The same name: `ssid
// modify` when its security changes or it was off, else nothing to declare —
// a new passphrase alone is the passphrase step and the reconcile. Then the
// reconcile that programs every access point (its preview is the delta, apply
// pushes it). The passphrase is never in argv: it goes to ap-manager on stdin
// through the secrets endpoint.
export function wifiSpecs(p: WifiPlan): { remove: StepSpec | null; declare: StepSpec | null; reconcile: StepSpec } {
  const reconcile: StepSpec = { bin: "ap-manager", verb: "reconcile", initial: {} };
  const add: StepSpec = { bin: "ap-manager", verb: "ssid add", words: ["ssid", "add"], initial: { "@ssid": p.ssid, "--zone": p.zone, "--security": p.security } };
  if (!p.old) return { remove: null, declare: add, reconcile };
  if (p.old.name !== p.ssid) {
    return { remove: { bin: "ap-manager", verb: "ssid remove", words: ["ssid", "remove"], initial: { "@ssid": p.old.name } }, declare: add, reconcile };
  }
  if (p.old.security === p.security && !p.old.disabled) return { remove: null, declare: null, reconcile };
  const mod: Values = { "@ssid": p.ssid };
  if (p.old.security !== p.security) mod["--security"] = p.security;
  if (p.old.disabled) mod["--enabled"] = true;
  return { remove: null, declare: { bin: "ap-manager", verb: "ssid modify", words: ["ssid", "modify"], initial: mod }, reconcile };
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
  pull: ["--host", "--contact", "--tunnel", "--endpoint", "--peer-key", "--tunnel-net", "--namespace", "--remote-namespace", "--store", "--port", "--schedule", "--location", "--country", "--city", "--building", "--mtu", "--config-only"],
  remote: ["--contact", "--tunnel", "--listen-port", "--peer-key", "--tunnel-net", "--auth-id", "--namespace", "--location", "--country", "--city", "--building", "--mtu", "--config-only"],
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
  location?: string; // one of the site's locations; else country and city find or add one
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
  // Where it is: a location of the site by name, or the place, which module
  // add finds among the site's locations or adds as one of kind remote.
  if (p.location) extra.push(`--location ${p.location}`);
  else if (p.country) {
    extra.push(`--country ${p.country}`);
    if (p.city) extra.push(`--city ${p.city}`);
  }
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
