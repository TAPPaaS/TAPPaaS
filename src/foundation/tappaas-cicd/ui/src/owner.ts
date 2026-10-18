// owner.ts — the site owner's view (ADR-034 D2, spike §5.11, mockup 7): the
// same reads, worded for a reader who does not know the gates ("short of
// memory", "backed up"), with the module's displayName as the start page shows
// it. Served on every route; it is what status.<domain> opens on.

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { HealthDoc, ModuleRow } from "./model";

export interface OwnerService {
  name: string;
  displayName: string;
  address: string | null; // where it is published, null: inside the site only
  state: string; // running, stopped, suspended
  notes: string[]; // "backed up", "short of memory", …
  level: "pass" | "warn" | "fail";
}

export interface OwnerSummary {
  site: string;
  sentence: string;
  facts: string[];
  services: OwnerService[];
  numbers: string;
  offsite: string[];
  release: string;
  operator: string | null;
}

export interface OwnerInputs {
  site: Record<string, unknown> | null;
  health: HealthDoc | null;
  modules: ModuleRow[];
  backup: { module: string; enabled: boolean; inPbsJob?: boolean }[] | null;
  topology: { nodes: unknown[]; switches: unknown[]; accessPoints: unknown[]; outside: { kind: string; name: string; location: string | null; state: string | null }[] } | null;
  // A module's displayName (its config) and where it is published (the
  // resolved proxyDomain of a module that depends on network:proxy).
  configs: Record<string, { displayName?: string; proxyDomain?: string | null; description?: string } | null>;
  lastSweep: { end_time?: string; reboot?: string; ok?: boolean } | null;
}

// Modules an owner uses: what is published or runs a service, not the
// platform's own parts.
const PLATFORM_STACKS = new Set(["foundation"]);

const findingsOn = (h: HealthDoc | null, module: string, gate: string): string[] =>
  (h?.gates ?? []).filter((g) => g.name === gate).flatMap((g) => g.findings.filter((f) => f.subject?.kind === "module" && f.subject.name === module && f.status !== "pass").map((f) => f.status));

export function ownerSummary(i: OwnerInputs): OwnerSummary {
  const site = i.site ?? {};
  const name = String(site.displayName ?? site.name ?? "your site");
  const backups = new Map((i.backup ?? []).map((b) => [b.module, b]));
  const services: OwnerService[] = i.modules
    .filter((m) => !PLATFORM_STACKS.has(m.stack ?? "") && m.kind !== "machine" && m.vmid !== null)
    .map((m) => {
      const c = i.configs[m.name] ?? {};
      const notes: string[] = [];
      const memory = findingsOn(i.health, m.name, "guest-memory");
      const live = findingsOn(i.health, m.name, "service-liveness");
      const b = backups.get(m.name);
      if (b && b.enabled && b.inPbsJob) notes.push("backed up");
      else if (b && !b.enabled) notes.push("not backed up");
      if (memory.length) notes.push("short of memory");
      if (live.length) notes.push("not answering");
      if (!c.proxyDomain) notes.push("inside the site only");
      const state = m.status === "suspended" ? "suspended" : m.running === "running" ? "running" : m.running || "unknown";
      const level: OwnerService["level"] = state !== "running" && state !== "suspended" ? "fail" : memory.length || live.length ? "warn" : "pass";
      return { name: m.name, displayName: c.displayName || m.name, address: c.proxyDomain ?? null, state, notes, level };
    })
    .sort((a, b) => a.displayName.localeCompare(b.displayName));

  const down = services.filter((s) => s.level === "fail");
  const short = services.filter((s) => s.notes.includes("short of memory"));
  const parts: string[] = [];
  parts.push(down.length === 0 ? "Everything is running." : `${down.length === 1 ? "One service is" : `${down.length} services are`} not running: ${down.map((s) => s.displayName).join(", ")}.`);
  if (short.length) parts.push(`${short.length === 1 ? "One service is" : `${short.length} services are`} short of memory.`);
  if (down.length || short.length) parts.push("Your operator has been told.");

  const facts: string[] = [];
  if (i.health) facts.push(`last check ${hhmm(i.health.generated)}`);
  const backed = services.filter((s) => s.notes.includes("backed up")).length;
  facts.push(`${backed} of ${services.length} services backed up`);
  const fw = (i.health?.gates ?? []).find((g) => g.name === "pulse");
  if (fw) facts.push(fw.status === "fail" ? "the pulse reports something down" : "internet and firewall up");
  if (site.ipv6 !== undefined) facts.push(`IPv6 ${site.ipv6 ? "on" : "off"}`);

  const t = i.topology;
  const numbers = t
    ? [`${t.nodes.length} server${t.nodes.length === 1 ? "" : "s"}`, `${t.switches.length} switch${t.switches.length === 1 ? "" : "es"}`, `${t.accessPoints.length} access point${t.accessPoints.length === 1 ? "" : "s"}`, "1 firewall"].join(" · ")
    : "";
  const offsite = (t?.outside ?? []).map((o) => `${o.kind === "satellite" ? "Satellite" : "Off-site copy"}: ${o.name}${o.location ? ` (${o.location})` : ""}${o.state === "down" ? " — not reachable" : o.state === "up" ? "" : " — not yet in touch"}`);
  const sched = site.updateSchedule as { frequency?: string } | undefined;
  // site.json's `version` is its schema's, not the release: the channel says what the site runs.
  const reboot = i.lastSweep?.reboot ?? "";
  const release = [site.channel ? `Channel ${String(site.channel)}` : "", sched?.frequency ? `updates ${sched.frequency === "daily" ? "nightly" : sched.frequency}` : "", reboot && !["none", "ok", "no", "false"].includes(reboot) ? `restarts: ${reboot}` : ""].filter((x) => x).join(" · ");
  return { site: name, sentence: parts.join(" "), facts, services, numbers, offsite, release, operator: typeof site.email === "string" ? site.email : null };
}

// The time of day on the mothership's clock (the site's timezone).
function hhmm(iso: string): string {
  const d = new Date(iso);
  return isNaN(d.getTime()) ? iso : `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

// A module's own config (displayName, dependsOn): the record, read directly;
// `resolved` gives the published name (the resolver's proxyDomain, default
// included), asked only of a module that depends on network:proxy.
export async function readConfigs(configDir: string, names: string[], resolved: (m: string) => Promise<string | null>): Promise<OwnerInputs["configs"]> {
  const out: OwnerInputs["configs"] = {};
  await Promise.all(
    names.map(async (n) => {
      const f = join(configDir, `${n}.json`);
      try {
        const c = existsSync(f) ? (JSON.parse(readFileSync(f, "utf8")) as { displayName?: string; dependsOn?: string[] }) : null;
        const published = (c?.dependsOn ?? []).includes("network:proxy");
        out[n] = c ? { displayName: c.displayName, proxyDomain: published ? await resolved(n).catch(() => null) : null } : null;
      } catch {
        out[n] = null;
      }
    }),
  );
  return out;
}
