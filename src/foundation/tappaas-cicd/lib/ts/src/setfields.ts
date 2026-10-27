// setfields.ts — `--set field=value` and `--unset field` for the modify verbs
// that took one flag per field before ADR-020 (D11).
//
// ADR-020 makes `modify <entity> --set field=value` the form every manager
// with declared fields offers. site-manager (site, location),
// environment-manager and identity-manager grew a flag per field first
// (`site modify --email …`). Those flags stay, as SHORTCUTS: each sets one
// field, and `--set` is expanded into them here, before the verb parses its
// arguments — so both spellings run the same code and refuse the same values.
//
// The tables below are the one record of which field each shortcut sets. The
// console builds its field forms from them (ui/src/fieldmanifest.ts), so a
// field added to a verb is added here once.

export type ShortcutTable = Record<string, string>; // schema field (dotted) → the verb's flag

const LOCATION: ShortcutTable = {
  displayName: "--displayName", kind: "--kind", country: "--country", city: "--city", address: "--address",
  timezone: "--timezone", latitude: "--latitude", longitude: "--longitude",
};
const ENVIRONMENT: ShortcutTable = {
  displayName: "--display", ownerOrg: "--owner", zone: "--zone", "domains.primary": "--domain", "domains.dnsMode": "--dns-mode",
};

export const MODIFY_SHORTCUTS = {
  site: {
    displayName: "--displayName", owner: "--owner", email: "--email", supportEmail: "--supportEmail", channel: "--channel",
    automaticReboot: "--automaticReboot", ipv6: "--ipv6", requireSigned: "--requireSigned", snapshotRetention: "--snapshotRetention",
    "backup.target": "--backupTarget", "backup.offsite": "--backupOffsite", "backup.defaultSchedule": "--backupDefaultSchedule",
    "backup.defaultRetention": "--backupDefaultRetention", primaryLocation: "--primaryLocation", locale: "--locale", keyboard: "--keyboard",
    "branding.logo": "--brandingLogo", "branding.logoDark": "--brandingLogoDark", "network.isp": "--networkIsp", "network.publicIp": "--networkPublicIp",
    dnssec: "--dnssec", "dnsBlocklists.lists": "--dnsBlocklistsLists", "dnsBlocklists.zones": "--dnsBlocklistsZones", "dnsBlocklists.allow": "--dnsBlocklistsAllow",
    "diskAutoGrow.enabled": "--diskAutoGrowEnabled", "diskAutoGrow.threshold": "--diskAutoGrowThreshold", "diskAutoGrow.growPercent": "--diskAutoGrowGrowPercent",
    "diskAutoGrow.minGrowGB": "--diskAutoGrowMinGrowGB", "diskAutoGrow.poolCeiling": "--diskAutoGrowPoolCeiling",
    "updateSchedule.frequency": "--updateFrequency", "updateSchedule.weekday": "--updateWeekday", "updateSchedule.hour": "--updateHour",
  },
  location: LOCATION,
  environment: ENVIRONMENT,
  org: { displayName: "--displayName", type: "--type", owner: "--owner", parentOrg: "--parentOrg" },
  group: { displayName: "--displayName", type: "--type", ownerOrg: "--ownerOrg", roles: "--roles" },
  user: { displayName: "--displayName", primaryEmail: "--email", state: "--state", roles: "--roles", memberOf: "--groups" },
  role: { displayName: "--displayName", description: "--description" },
} satisfies Record<string, ShortcutTable>;

export class SetError extends Error {}

export interface ExpandOptions {
  // What `--unset f` becomes:
  //   "list"  one `--unset f,g` the verb handles itself (site, location)
  //   "empty" the field's flag with "" (identity: an emptied list)
  //   "no"    refused: the verb has no way to empty a field
  unset: "list" | "empty" | "no";
  // Why a field the table lacks cannot be set (its change class), if known.
  whyNot?: (field: string) => string | null;
}

// A JSON list (how the console sends one) becomes the comma list the shortcuts take.
function flagValue(v: string): string {
  if (!v.startsWith("[")) return v;
  try {
    const a = JSON.parse(v) as unknown;
    if (Array.isArray(a) && a.every((x) => typeof x === "string" || typeof x === "number")) return a.join(",");
  } catch { /* not JSON: as given */ }
  return v;
}

// argv with every `--set field=value` / `--unset field` turned into the verb's
// own flags. Throws SetError, worded for the operator, on a field the verb does
// not set, a malformed --set, or a field given two different values.
export function expandSet(argv: string[], table: ShortcutTable, verb: string, opts: ExpandOptions): string[] {
  if (!argv.includes("--set") && !argv.includes("--unset")) return argv;
  const known = (f: string): void => {
    if (table[f]) return;
    const why = opts.whyNot?.(f);
    throw new SetError(`${verb}: ${f} ${why ? `cannot be set — ${why}` : `is not a field ${verb} sets (fields: ${Object.keys(table).join(", ")})`}`);
  };
  const out: string[] = [];
  const unsets: string[] = [];
  const given = new Map<string, string>(); // flag → value, from --set
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a !== "--set" && a !== "--unset") {
      out.push(a);
      continue;
    }
    const v = argv[i + 1];
    if (v === undefined || v.startsWith("--")) throw new SetError(`${verb}: ${a} needs ${a === "--set" ? "field=value" : "a field"}`);
    i++;
    if (a === "--unset") {
      for (const f of v.split(",").map((x) => x.trim()).filter(Boolean)) {
        known(f);
        unsets.push(f);
      }
      continue;
    }
    const eq = v.indexOf("=");
    if (eq <= 0) throw new SetError(`${verb}: --set takes field=value (got '${v}')`);
    const field = v.slice(0, eq);
    known(field);
    const flag = table[field];
    const value = flagValue(v.slice(eq + 1));
    if (given.has(flag) && given.get(flag) !== value) throw new SetError(`${verb}: ${field} is given two values`);
    given.set(flag, value);
  }
  // A shortcut given beside --set for the same field must agree with it.
  for (const [flag, value] of given) {
    const j = out.indexOf(flag);
    if (j >= 0 && out[j + 1] !== value) throw new SetError(`${verb}: ${flag} and --set disagree on the same field`);
    if (j < 0) out.push(flag, value);
  }
  if (unsets.length) {
    if (opts.unset === "no") throw new SetError(`${verb}: a field cannot be emptied here (${unsets.join(", ")}): give it a value`);
    for (const f of unsets) if (given.has(table[f])) throw new SetError(`${verb}: ${f} is both set and unset`);
    if (opts.unset === "list") out.push("--unset", unsets.join(","));
    else for (const f of unsets) out.push(table[f], "");
  }
  return out;
}
