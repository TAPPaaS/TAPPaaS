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
// `ap-controller list --json`.
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

// An SSID's name as ap-controller and ~/.wlan-secrets.txt take it: 1–32
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
    remove: p.replace ? { bin: "ap-controller", verb: "ssid remove", words: ["ssid", p.replace.ap, "remove"], initial: { "@ssid": p.replace.ssid } } : null,
    add: { bin: "ap-controller", verb: "ssid add", words: ["ssid", p.ap, "add"], initial: add },
    reconcile: { bin: "ap-controller", verb: "reconcile", initial: {} },
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
