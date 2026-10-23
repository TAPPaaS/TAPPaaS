// site-manager — TAPPaaS Site manager (ADR-007 P2, all-managers-to-TS #3).
//
// The Site is the umbrella over a whole TAPPaaS installation (site-wide
// identity, location, hardware nodes + storage pools, backup, update schedule,
// module repositories). It is a SINGLETON: exactly one config/site.json.
//
// Entity model (the entity is the first arg):
//   site       (SINGLETON) → show | modify
//   node                   → list | add | delete
//   repository             → list | add | modify | delete | reconcile
// Plus top-level lifecycle verbs:
//   add        create the site singleton (= create-site.sh: cluster discovery)
//   validate   validate site.json well-formed (= validate-site.sh)
//   reconcile  converge config → live (site.json + repositories;
//              with --deep: cascade to people + network + environments)
//
// TS owns config CRUD (site modify, node …) + validate + reconcile; the heavy
// git/cluster I/O stays in the still-live bash tools, invoked as thin
// delegations: `add` → create-site.sh; `repository add`/`delete` →
// repository.sh; `validate` → validate-site.sh. The transitional migration
// the legacy config->site migration is retired; not ported and not wired here.
//
// Exit codes: ok=0, error=1.

import { DEFAULT_HOLD, describeHold, makeHold, parseUntil, readHolds, releaseHold, validRepoName, writeHold } from "./hold";
import { UNIT, buildRequest, dropRequest, readResult, repoStatusLine, summaryLine, writeRequest } from "./unitrun";
import { clusterScript, defaultConfigDir, defaultSchemaDir, loadRaw, loadSite, refusedField, siteSchema, writeSite } from "./config";
import { CliSiteClient } from "./client";
import { HelpSpec, checkArgs, renderHelp } from "../../../lib/ts/src/help";
import { evacuateNode, evacuateExitCode } from "./evacuate";
import { DieError, GN, RD, YW, CL, debug, die, guarded, info, infoTagged, preflightGuard, warn } from "../../../lib/ts/src/cli";
import { applyPlan, computePlan } from "./reconcile";
import { adoptNode, provisionNode } from "./provision";
import { Site, SiteClient, SiteNode } from "./types";
import { runningVersion } from "./version";
import { spawnSync } from "child_process";
import { existsSync, readFileSync } from "fs";
import { dirname } from "path";
import { locationErrors, readLocations } from "../../../lib/ts/src/locations";

const VERSION = "0.1.0";

export const HELP: HelpSpec = {
  name: "site-manager",
  version: VERSION,
  tagline: "TAPPaaS Site manager: the site, its nodes, its repositories and its updates",
  verbs: [
    { usage: "site show [--json]" },
    {
      usage: "site modify <field options>", effect: { noPreview: "writes the fields given into site.json" },
      name: "site modify (fields; at least one)",
      // Accepted so the refusal can say why (the schema's change class); the
      // --location* spellings are the retired location's, for one release:
      // locale and keyboard go to the site, the others to the primary location.
      hidden: ["--name <s>", "--version <s>", "--defaultEnvironment <s>",
        "--locationCountry <cc>", "--locationTimezone <tz>", "--locationLocale <l>", "--locationKeyboard <kb>",
        "--locationLatitude <deg>", "--locationLongitude <deg>", "--locationCity <c>", "--locationBuilding <f>"],
      options: [
        ["--channel <c>", "release channel: unstable | staging | production. Checks EVERY registered repository against the branch it declares for that channel in its channels.json, warns where they disagree or where none is declared, and proposes the fix; moving towards production needs --force."],
        ["--force", "authorize a channel move towards production — older code, and migrations do not run backwards."],
        ["--displayName <s>", "display name"],
        ["--owner <org>", "owning organization"],
        ["--email <addr>", "admin email"],
        ["--automaticReboot true|false", "allow update reboots"],
        ["--ipv6 true|false", "the site supports IPv6: OPNsense's 'Allow IPv6', applied by the next network update (default false)"],
        ["--requireSigned true|false", "refuse to update a staging/production repository that signs no releases (ADR-033 D9; default false). A repository that lists signing keys is verified either way."],
        ["--snapshotRetention <n>", "VM snapshots kept per module"],
        ["--backupTarget <s>", "backup.target"],
        ["--backupOffsite <s>", "backup.offsite"],
        ["--backupDefaultSchedule <s>", "backup.defaultSchedule: daily | weekly | monthly | HH:MM"],
        ["--backupDefaultRetention <s>", "backup.defaultRetention, e.g. 90d"],
        ["--primaryLocation <name>", "the location the site is at: one of the site's locations (location list), with a timezone — the site's"],
        ["--locale <l>", "the site's POSIX locale, e.g. en_US"],
        ["--keyboard <kb>", "the console keyboard layout every OS family is set from, e.g. dk"],
        ["--brandingLogo <path>", "branding.logo — the sign-in page's logo (svg, png, jpg, webp), relative to the config dir; applied by the identity update"],
        ["--brandingLogoDark <path>", "branding.logoDark — its dark-theme variant, same file type"],
        ["--dnssec true|false", "the firewall's resolver validates DNSSEC (default true); applied by the next network update"],
        ["--dnsBlocklistsLists <a,b>", "dnsBlocklists.lists — OPNsense blocklist codes (atf, hgz011, oisd1, ag, …); '' blocks nothing. Applied by the next network update"],
        ["--dnsBlocklistsZones <a,b>", "dnsBlocklists.zones — the zones whose clients are filtered; '' filters every client"],
        ["--dnsBlocklistsAllow <a,b>", "dnsBlocklists.allow — domains never blocked"],
        ["--diskAutoGrowEnabled true|false", "diskAutoGrow.enabled — grow a VM's disk when its / fills up, at every module update"],
        ["--diskAutoGrowThreshold <pct>", "diskAutoGrow.threshold — grow at or over this % full (default 80)"],
        ["--diskAutoGrowGrowPercent <pct>", "diskAutoGrow.growPercent — grow by this % of the disk (default 50)"],
        ["--diskAutoGrowMinGrowGB <gb>", "diskAutoGrow.minGrowGB — and by at least this many GB (default 5)"],
        ["--diskAutoGrowPoolCeiling <pct>", "diskAutoGrow.poolCeiling — only while the pool stays at or under this % used (default 80)"],
        ["--networkIsp <s>", "network.isp"],
        ["--networkPublicIp <ip>", "network.publicIp (or auto)"],
        ["--updateFrequency <f>", "daily | weekly | monthly | none"],
        ["--updateWeekday <Day>", "Monday … Sunday (weekly/monthly only)"],
        ["--updateHour <0-23>", "hour of the update window"],
      ],
    },
    { usage: "node list [--json]" },
    { usage: "node add <N> [--pxe] [--boot-disk <d>] [--mac <m>] [--wan-port <if>|--no-wan] [--lan-ports <a,b>] [--lan-mode <m>] [--lan-primary <if>] [--pool <p>] [--ttl <s>] [--config-only] [--yes]", effect: { noPreview: "joins a node: PXE-boots and installs it, adds it to the cluster and site.json" },
      hidden: ["--name <N>", "--provision"],
      options: [
        ["(default)", "Adopt a Proxmox already installed at the node's designated mgmt IP: join the cluster + capture."],
        ["--pxe", "Bare machine: PXE-install first, then join + capture. Omit --boot-disk to be asked on the NODE console; WAN port + pools are asked here."],
        ["--boot-disk <serial>", "--pxe: the disk to install Proxmox on, by SERIAL (lsblk -o NAME,SERIAL) — kernel names move between boots."],
        ["--mac <m>", "--pxe: the NIC that PXE-boots."],
        ["--wan-port <if>", "the node's WAN interface."],
        ["--no-wan", "the node has no WAN port."],
        ["--lan-ports <a,b>", "the node's lan port(s); two or more bond under lan as lanbond. Default: auto-detected, one port."],
        ["--lan-mode <m>", "active-backup (default for 2+ ports: any switches, any speeds) or lacp (equal speeds; the switch side one LAG)."],
        ["--lan-primary <if>", "active-backup: the port that carries traffic when up (default: the fastest)."],
        ["--pool <p>", "a storage pool on the node (more pools: extra positionals)."],
        ["--ttl <s>", "--pxe: seconds the PXE offer stays open (default 7200)."],
        ["--yes", "do not ask for confirmation."],
        ["--config-only", "Only write the site.json entry (no machine contact)."],
      ] },
    { usage: "node delete <name> [--apply] [--shutdown] [--erase] [--config-only]",
      options: [
        ["(default)", "Preview: what still holds the node (guests, replication, HA rules, the PBS) and the plan. Changes nothing."],
        ["--apply", "Remove it from the cluster (pvecm delnode, /etc/pve/nodes/<n>, storage entries, known_hosts), then from site.json; its pvehost module is archived. Refused while anything holds it; asks for the node name."],
        ["--shutdown", "Power the node off first — Proxmox removes a node only once it is off. A node that is already down needs nothing."],
        ["--erase", "Before the power-off: destroy its ZFS pools and wipe their disks, wipe the boot disk's partitions and partition table, delete its boot entry. Asks for ERASE as well. Implies --shutdown."],
        ["--config-only", "Only drop the site.json entry and the pvehost module; the cluster is not touched."],
      ] },
    { usage: "node reboot <name> [--apply]",
      options: [
        ["(default)", "Preview the reboot's impact — which HA services drain where. Changes nothing."],
        ["--apply", "Perform the controlled reboot (drain HA services, reboot, rejoin, fail back)."],
      ] },
    { usage: "node qdevice add <host> [--user <u>] [--force] | remove [--user <u>] | status", effect: { noPreview: "adds or removes the cluster's quorum device" }, readWhen: ["status"],
      options: [
        ["add <host>", "A third vote for a two-node cluster: corosync-qnetd on <host> (a small always-on Debian machine, not a node), corosync-qdevice on every node, then pvecm qdevice setup; the first node's root login on <host>, which the setup needs, is removed afterwards. Restarts corosync on every node."],
        ["--user <u>", "How the mothership logs in to the QDevice's host (default tappaas, with sudo; root works too)."],
        ["--force", "Also on an odd number of nodes, which Proxmox does not support."],
        ["remove", "pvecm qdevice remove, and the first node's root login on the QDevice's host is removed; the packages stay."],
      ] },
    { usage: "node network show <node> [--json]",
      options: [
        ["(default)", "The node's lan uplink, declared next to live: ports, mode, state, speed, the LACP aggregator, the switch each port reaches (LLDP), corosync — and what is wrong with it."],
        ["--json", "The declaration, the probe and the findings as JSON."],
      ] },
    { usage: "node network set <node> [--lan-ports <a,b>] [--lan-mode <m>] [--lan-primary <if>] [--mtu <n>] [--no-wan | --wan-port <p>] [--switch-wait <s>] [--config-only] [--apply] [--yes]",
      options: [
        ["(default)", "Declare the uplink in config/<node>.json (uplinks.lan, ports by MAC) and preview the change on the node. Without --lan-ports: the declaration there is."],
        ["--lan-ports <a,b>", "Ports by name or MAC. One port, or two or more bonded as lanbond."],
        ["--lan-mode <m>", "active-backup (default: any switches, any speeds — 10G + 1G) or lacp (equal speeds; the switch side one LAG: one switch or a stack/MLAG pair)."],
        ["--lan-primary <if>", "active-backup: the port that carries traffic when up (default: the fastest)."],
        ["--mtu <n>", "MTU on the bond and the lan bridge (the switch ports must match)."],
        ["--no-wan", "The wan bridge gives up its port, so it can join the lan bond (e.g. a 1G wan port as lan's backup leg). The node can then no longer carry the firewall's WAN; refused while a guest uses the wan bridge."],
        ["--wan-port <p>", "The wan bridge carries <p> (by name or MAC): the reverse of --no-wan, so the firewall's WAN role can move to this node (#849). Not one of the lan ports. Moving the firewall's failover there also takes the network module's HANode and the switch port as an access port in the WAN VLAN (cluster README)."],
        ["--switch-wait <s>", "With --apply: wait up to <s> seconds (30–1800, default 30) for the change to verify, to configure the switch side meanwhile — e.g. the LAG for lacp, once the node speaks it. Needs the drained node's HA watchdog released."],
        ["--config-only", "Declare only, without contacting the node (ports by MAC)."],
        ["--apply", "Converge: drain the node (HA maintenance), carry lan on the declared ports under a 45s rollback, confirm from the mothership, bring the node back. One node at a time."],
        ["--yes", "Do not ask for the node name."],
      ] },
    { usage: "node network test <node> [--apply] [--yes]", effect: { apply: "--apply" },
      options: [
        ["(default)", "Preview the failover test."],
        ["--apply", "Drain the node, then take each lan leg down for 10s in turn: mgmt and corosync must stay up. A timer on the node restores the leg after 30s whatever happens."],
        ["--yes", "Do not ask for the node name."],
      ] },
    { usage: "node reconcile [--apply]",
      options: [["--apply", "Register nodes that joined the cluster (default is preview)."]] },
    { usage: "repository list [--json]", note: "(alias: repo)" },
    { usage: "repository add <url> [--branch <b>] [--managed full|tracked] [--catalog <p>] [--introduction <tag> --signer <fp> | --unsigned]", effect: { noPreview: "clones the repository into ~/<name> and registers it in site.json" },
      options: [
        ["--branch <b>", "Branch to check out (default stable)."],
        ["--managed full|tracked", "full: carries modules, its catalog is validated; tracked: registered without catalog requirements. The sweep pulls both."],
        ["--catalog <p>", "Path of the module catalog inside the repository."],
        ["--introduction <tag>", "ADR-033 D5: the release tag trust starts from, from the repository's owner. With --signer, required on a staging/production branch; the clone must verify against it, and it is recorded as the entry's trust."],
        ["--signer SHA256:<fp>", "Fingerprint of the key that signed the introduction (ssh-keygen -l), obtained from the owner out of band."],
        ["--unsigned", "Add a staging/production branch without an introduction: a repository that signs nothing, or one trusted from the revision cloned now (D9)."],
      ] },
    { usage: "repository introduce <name> [--introduction <tag> --signer <fp>]",
      note: "(ADR-033 D5: check the checkout against its trust anchor and record it)",
      options: [
        ["--introduction <tag>", "Give an existing repository an anchor: the release tag to trust first. Written to site.json once the checkout verifies against it."],
        ["--signer SHA256:<fp>", "Fingerprint of the key that signed that tag, from the repository's owner."],
      ] },
    { usage: "repository modify <name> [--url <u>] [--branch <b>]", effect: { noPreview: "changes the repository's URL or branch in site.json (a new URL re-clones it)" },
      options: [["--url <u>", "Re-point the repo at a new forge/URL in place (e.g. github.com→codeberg.org)."],
                ["--branch <b>", "Switch the checked-out branch."]] },
    { usage: "evacuate <node> [--force]", effect: { noPreview: "migrates every guest off the node" },
      name: "evacuate",
      note: "(clear a node for maintenance, via module-manager per module)",
      options: [["--force", "authorize an OFFLINE move for guests that cannot migrate live"]] },
    { usage: "repository delete <name> [--force]", effect: { noPreview: "unregisters the repository and removes its clone" },
      options: [["--force", "Forward to repository.sh remove --force."]] },
    { usage: "repository stash [list [<name>] | show <name> <sha> | restore <name> <sha> | discard <name> <sha>]", effect: { noPreview: "restores or discards a stash the update kept" }, readWhen: ["list", "show"],
      note: "(the local changes a sync set aside — listed with their age, inspectable, restorable, discardable)",
      options: [["--force", "Confirm a discard. Dropping a stash entry cannot be undone, so `discard` refuses without it."]] },
    { usage: "repository reconcile [--apply]",
      note: "(presence and branch; how far behind origin is reported, and `sync` closes it)",
      options: [["--apply", "Commit (default is preview)."]] },
    { usage: "repository sync <name> [--dry-run]",
      note: "(one repository to its branch tip, without the sweep; deploys no module)",
      options: [["--dry-run", "Report the commits, any pending migration and the installed modules it would move; change nothing."]] },
    { usage: "repository hold <name> --reason <text> [--until <30m|12h|7d|ISO date>]", effect: { noPreview: "holds the repository at its current commit in site.json: the update leaves it" },
      note: "(the scheduled sweep skips this repository's pull until the hold expires)",
      options: [["--reason <text>", "Why the pull is held (shown in every sweep log)."],
                ["--until <when>", `When the hold expires (default ${DEFAULT_HOLD}); the next sweep then pulls again.`]] },
    { usage: "repository release <name>", effect: { noPreview: "ends the hold in site.json" }, note: "(end a hold now)" },
    { usage: "add --name <site-code> [--organization <org>] [create-site options]", effect: { noPreview: "creates config/site.json from the running cluster" },
      name: "add (create config/site.json from the running cluster — create-site.sh)",
      hidden: ["--org <org>"],
      options: [
        ["--name <N>", "REQUIRED. Site code = the Proxmox cluster name."],
        ["--organization <org>", "Default organization/environment/zone (default: --name)."],
        ["--domain <d>", "Public domain (per environment; not written to site.json)."],
        ["--branch <b>", "Git branch to track (default: stable)."],
        ["--upstream-git <url>", "Module-catalog git repo (default: codeberg.org/TAPPaaS/TAPPaaS)."],
        ["--email <addr>", "Admin email (default: Proxmox root@pam / existing)."],
        ["--primary-node <fqdn>", "Node to discover the cluster from (default: tappaas1)."],
        ["--schedule <f>", "Update frequency: monthly|weekly|daily|none (default: weekly)."],
        ["--weekday <Day>", "Weekday for updates (default: Tuesday)."],
        ["--hour <H>", "Hour of day 0-23 (default: 2)."],
        ["--force", "Overwrite an existing site.json."],
      ] },
    { usage: "validate [FILE] [--schema-dir PATH]",
      options: [["--schema-dir PATH", "Directory holding site-fields.json (default: derived)."]] },
    { usage: "reconcile [--apply] [--deep]",
      options: [
        ["--apply", "Commit (default is preview)."],
        ["--deep", "Cascade people → network → (every) environment."],
      ] },
    { usage: "update [--dry-run] [--force] [--allow-disruption] [--no-git-pull]",
      note: "(run the whole-site update sweep NOW — packages update-tappaas)",
      options: [
        ["--dry-run", "Preview the update plan; change nothing."],
        ["--force", "Update every module even when its pre-update test failed fatally, or its status is archived/external. Never reboots anything."],
        ["--allow-disruption", "Open the downtime window for this run: a module with rebootOk may be rebooted or migrated offline, the others keep their disruptive changes deferred. Never overrides rebootOk:false — that is `module-manager module update <m> --allow-disruption`."],
        ["--no-git-pull", "Update whatever is checked out; skip pulling each repository (test local, not-yet-pushed changes)."],
      ] },
    { usage: "test [--deep]",
      note: "(run every deployed module's tests, from every repository)",
      options: [
        ["--deep", "Forward --deep to each module test (heavy / regression suite; creates real VMs)."],
      ] },
  ],
  common: [
    ["--config-dir DIR", "Config root (default: $TAPPAAS_CONFIG or /home/tappaas/config)."],
    ["--json", "Machine-readable output for list/show."],
  ],
  notes: [
    "Owns config/site.json (the Site singleton). add (create-site.sh), repository\n" +
      "add/modify/delete (repository.sh) are thin delegations to the still-live bash\n" +
      "tools; validate wraps validate-site.sh. TS owns config CRUD + validate + reconcile.",
  ],
};

function usage(): void {
  info(renderHelp(HELP));
}

// ── option parsing ─────────────────────────────────────────────────────
interface Opts {
  configDir: string;
  siteFile?: string;
  schemaDir: string;
  apply: boolean;
  deep: boolean;
  force: boolean;
  json: boolean;
  // generic --key value capture for `site modify` / `node add` / `repository add`.
  flags: Map<string, string>;
  boolFlags: Set<string>;
  rest: string[];
}

// Flags that take NO value (everything else with a value is captured generically).
const NOARG = new Set(["--apply", "--deep", "--force", "--json",
  "--pxe", "--provision", "--config-only", "--yes", "--no-wan",
  "--dry-run", "--no-git-pull", "--allow-disruption", "--shutdown", "--erase", "--unsigned"]);

function parseOpts(args: string[]): Opts {
  const o: Opts = {
    configDir: defaultConfigDir(),
    schemaDir: defaultSchemaDir(),
    apply: false,
    deep: false,
    force: false,
    json: false,
    flags: new Map(),
    boolFlags: new Set(),
    rest: [],
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--config-dir") {
      const v = args[i + 1];
      if (!v) die("--config-dir requires a path argument");
      o.configDir = v;
      i++;
    } else if (a === "--schema-dir") {
      const v = args[i + 1];
      if (!v) die("--schema-dir requires a path argument");
      o.schemaDir = v;
      i++;
    } else if (a === "--apply") {
      o.apply = true;
    } else if (a === "--deep") {
      o.deep = true;
    } else if (a === "--force") {
      o.force = true;
    } else if (a === "--json") {
      o.json = true;
    } else if (a.startsWith("--")) {
      // generic flag. If the next token is a value (not another flag), capture it.
      const next = args[i + 1];
      if (NOARG.has(a) || next === undefined || next.startsWith("--")) {
        o.boolFlags.add(a);
      } else {
        // allow repeated --pool: store last; node add reads rest for pools.
        o.flags.set(a, next);
        i++;
      }
    } else {
      o.rest.push(a);
    }
  }
  return o;
}

// A deleted node's pvehost module instance (ADR-026 D4) goes with it: archived
// and unregistered, never --decommission — the machine is not touched. Left
// behind, it is a module for a node the site no longer has (#729 §3).
function unregisterNodeModule(name: string, configDir: string): void {
  const cfg = `${configDir.replace(/\/$/, "")}/${name}.json`;
  if (!existsSync(cfg)) return;
  try {
    if (!String(JSON.parse(readFileSync(cfg, "utf8")).moduleSource ?? "").endsWith("/pvehost")) return;
  } catch { return; }
  const r = spawnSync("module-manager", ["delete", name, "--archive", "--yes"], { stdio: "inherit" });
  if (r.status === 0) info(`${GN}✓${CL} its pvehost module instance is archived and unregistered`);
  else warn(`the pvehost module instance '${name}' is still registered — module-manager delete ${name}`);
}

function siteFileOf(o: Opts): string {
  return o.siteFile ?? `${o.configDir.replace(/\/$/, "")}/site.json`;
}

// ── `site` (singleton) ─────────────────────────────────────────────────
function cmdSite(o: Opts): void {
  const sub = o.rest[0];
  if (!sub) die("site: expected 'show' or 'modify'");
  const siteFile = siteFileOf(o);

  if (sub === "show") {
    const raw = loadRaw(siteFile);
    if (Object.keys(raw).length === 0) die(`site.json not found: ${siteFile}`);
    // --json → the exact on-disk document; default → a concise human summary
    // (consistent with `node list` / `repository list`).
    if (o.json) {
      info(JSON.stringify(raw, null, 2));
      return;
    }
    const site: Site = loadSite(siteFile);
    const loc = site.location ?? ({} as Site["location"]);
    const net = site.network ?? {};
    // Either shape; daily/none carry no weekday (#447, ADR-017 D7).
    const sched = readSchedule(site.updateSchedule);
    const schedStr = sched.frequency
      ? [
          sched.frequency,
          sched.weekday,
          sched.hour != null && sched.frequency !== "none" ? `@ ${String(sched.hour).padStart(2, "0")}:00` : null,
        ]
          .filter((x) => x != null && x !== "")
          .join(" ")
      : "(unset)";
    const nodes = site.hardware?.nodes ?? [];
    const repos = site.repositories ?? [];
    const lbl = (k: string): string => `${GN}${(k + ":").padEnd(15)}${CL}`;
    info(`${lbl("Site")}${site.name}${site.displayName && site.displayName !== site.name ? ` (${site.displayName})` : ""}`);
    info(`${lbl("Owner")}${site.owner || "(unset)"}`);
    info(`${lbl("Email")}${site.email || "(unset)"}`);
    // The code's version, read live from the checkout (ADR-028 D13). site.json's
    // `version` is the release the site was installed from, written once.
    const tp = repos.find((r) => r.name === "TAPPaaS")?.path ?? "/home/tappaas/TAPPaaS";
    const running = runningVersion(tp);
    info(`${lbl("TAPPaaS")}${running ?? "(no release tag in the checkout)"}${site.channel ? `  (${site.channel} channel)` : ""}`);
    info(`${lbl("Installed from")}${site.version || "(unset)"}`);
    info(`${lbl("Location")}${[loc.country, loc.timezone, loc.locale, loc.keyboard].filter(Boolean).join(" / ") || "(unset)"}`);
    // #609: where the site physically is — what an off-site copy is compared with.
    if (loc.city || loc.building) {
      info(`${lbl("Place")}${[loc.building, loc.city, loc.country].filter(Boolean).join(", ")}`);
    }
    if (loc.latitude !== undefined || loc.longitude !== undefined) {
      info(`${lbl("Position")}${[loc.latitude, loc.longitude].map((v) => (v === undefined ? "?" : String(v))).join(", ")}`);
    }
    info(`${lbl("Network")}publicIp=${net.publicIp ?? "(unset)"}  isp=${net.isp ?? "(none)"}  ipv6=${site.ipv6 ? "yes" : "no"}`);
    info(`${lbl("Update")}${schedStr}  (auto-reboot: ${site.automaticReboot ? "yes" : "no"}, keep ${site.snapshotRetention ?? "?"})`);
    info(`${lbl("Nodes")}${nodes.length ? nodes.map((n) => `${n.name} [${n.storagePools.join(", ")}]`).join("  ") : "(none)"}`);
    // ADR-033 D10: what each repository runs, from the last signature check.
    const sigFile = `${o.configDir.replace(/\/$/, "")}/sbom/signatures.json`;
    let sigs: Record<string, string> = {};
    try {
      const doc = JSON.parse(readFileSync(sigFile, "utf8")) as { repositories?: { name: string; status: string; tag?: string }[] };
      for (const r of doc.repositories ?? []) sigs[r.name] = r.status === "verified" ? `verified ${r.tag ?? ""}`.trim() : r.status;
    } catch {
      sigs = {};
    }
    info(`${lbl("Repositories")}${repos.length ? repos.map((r) => `${r.name}${r.branch ? "@" + r.branch : ""}${sigs[r.name] ? ` [${sigs[r.name]}]` : ""}`).join("  ") : "(none)"}` +
      (site.requireSigned ? "  — signed releases required" : ""));
    info(`${lbl("Backup")}${site.backup ? JSON.stringify(site.backup) : "(none)"}`);
    return;
  }

  if (sub === "modify") {
    const raw = loadRaw(siteFile);
    if (Object.keys(raw).length === 0) die(`site.json not found: ${siteFile}`);
    // A field whose change class is not in-place is refused before anything
    // is written, with the schema's reason.
    for (const field of ["name", "version", "defaultEnvironment"]) {
      if (!o.flags.has(`--${field}`) && !o.boolFlags.has(`--${field}`)) continue;
      die(`site modify: --${field} is refused — ${refusedField(siteSchema(o.schemaDir), field) ?? "not changed by site modify"}`);
    }
    let changed = 0;
    // The approved editable surface: scalar site-wide fields, mapped to schema
    // paths. The discovery-derived hardware.nodes[] and the repositories list
    // are NOT modifiable here — each has its own CRUD (node …, repository …).
    // (Environments and organizations are not site fields at all — they are the
    // config/environments/ and config/identities/organizations/ files.)
    const setStr = (flag: string, path: string[]): void => {
      const v = o.flags.get(flag);
      if (v === undefined) return;
      setDeep(raw, path, v);
      changed++;
    };
    const setBool = (flag: string, path: string[]): void => {
      const v = o.flags.get(flag);
      if (v === undefined) return;
      if (v !== "true" && v !== "false") die(`${flag} must be true|false`);
      setDeep(raw, path, v === "true");
      changed++;
    };
    const setInt = (flag: string, path: string[]): void => {
      const v = o.flags.get(flag);
      if (v === undefined) return;
      const n = parseInt(v, 10);
      if (!Number.isInteger(n)) die(`${flag} must be an integer`);
      setDeep(raw, path, n);
      changed++;
    };
    // A coordinate is not an integer: 55.6761 is the point of it (#408).
    const setNum = (flag: string, path: string[], min: number, max: number): void => {
      const v = o.flags.get(flag);
      if (v === undefined) return;
      const n = Number(v);
      if (!Number.isFinite(n)) die(`${flag} must be a number, in decimal degrees`);
      if (n < min || n > max) die(`${flag} must be between ${min} and ${max}`);
      setDeep(raw, path, n);
      changed++;
    };

    // A comma list; '' is the empty list.
    const setList = (flag: string, path: string[]): void => {
      const v = o.flags.get(flag) ?? (o.boolFlags.has(flag) ? "" : undefined);
      if (v === undefined) return;
      setDeep(raw, path, v.split(",").map((x) => x.trim()).filter(Boolean));
      changed++;
    };
    const setRange = (flag: string, path: string[], min: number, max: number): void => {
      const v = o.flags.get(flag);
      if (v === undefined) return;
      if (!/^\d+$/.test(v) || Number(v) < min || Number(v) > max) die(`${flag} must be an integer ${max === Infinity ? `of ${min} or more` : `${min}-${max}`}`);
      setDeep(raw, path, Number(v));
      changed++;
    };

    // ── channel (ADR-028 D9) ───────────────────────────────────────────
    // A promise about risk, not a location: the branch each repository tracks
    // is where the code sits. They are expected to agree, and this warns when
    // they do not rather than refusing — a site may legitimately sit between
    // the two for a moment while the operator moves both.
    const CHANNELS = ["unstable", "staging", "production"] as const;

    // Which branch realizes which channel is the REPOSITORY's statement, read
    // from channels.json at its root (ADR-028 D11) — not a map hardcoded here,
    // which was only ever true of the TAPPaaS source. Returns null when the
    // repository declares nothing, so a caller can tell "unstable" from
    // "nobody said"; the difference is the whole point of the warning.
    const declaredChannels = (repoPath?: string): Record<string, string[]> | null => {
      if (!repoPath) return null;
      const f = `${repoPath}/channels.json`;
      if (!existsSync(f)) return null;
      try {
        const j = JSON.parse(readFileSync(f, "utf8")) as Record<string, unknown>;
        const out: Record<string, string[]> = {};
        for (const [k, v] of Object.entries(j)) {
          if (k.startsWith("_")) continue;        // _README and friends
          if (Array.isArray(v)) out[k] = v.filter((x): x is string => typeof x === "string");
        }
        return out;
      } catch { return null; }                     // unreadable reads as undeclared
    };
    // A branch listed in no channel is UNSTABLE — the safe direction, so an
    // unrecognised branch is never mistaken for production.
    const branchChannel = (decl: Record<string, string[]>, branch: string): string => {
      for (const c of CHANNELS) if ((decl[c] ?? []).includes(branch)) return c;
      return "unstable";
    };
    const setChannel = (): void => {
      const v = o.flags.get("--channel");
      if (v === undefined) return;
      if (!CHANNELS.includes(v as typeof CHANNELS[number])) {
        die(`--channel must be one of: ${CHANNELS.join(" | ")}`);
      }
      const from = typeof raw.channel === "string" ? raw.channel : undefined;
      // "Towards production" means towards OLDER code. ADR-025 migrations are
      // forward-only, so a site that has applied one cannot run code that
      // predates it — the move is allowed, but not by accident.
      const rank = (c?: string): number => (c ? CHANNELS.indexOf(c as typeof CHANNELS[number]) : -1);
      if (from && rank(v) > rank(from)) {
        const forced = o.flags.has("--force");
        const msg = `${from} → ${v} moves this site BACKWARDS, to older code. `
          + `Config migrations (ADR-025) do not run backwards, so a migration this site has `
          + `already applied cannot be undone by switching channel.`;
        if (!forced) {
          die(`${msg}\n       Re-run with --force if that is what you mean.`);
        }
        warn(msg);
        warn(`--force given: setting the channel anyway.`);
      }
      setDeep(raw, ["channel"], v);
      changed++;
      // The branch is not changed here — repository modify owns it — but a
      // disagreement is worth saying at the moment it is created.
      // EVERY registered repository, not just TAPPaaS (ADR-028 D11): the channel
      // is a claim about everything this site tracks. A site on `production`
      // whose Community checkout sits on somebody's `main` is not a production
      // site. Nothing is switched here — repository modify owns the branch, and
      // a branch change is a code change to a live site — but the disagreement
      // is named at the moment it is created, with the command that settles it.
      const repos = Array.isArray(raw.repositories) ? raw.repositories : [];
      let undeclared = 0, disagree = 0;
      for (const r of repos as Array<Record<string, unknown>>) {
        const name = typeof r.name === "string" ? r.name : "?";
        const br = typeof r.branch === "string" ? r.branch : undefined;
        const path = typeof r.path === "string" ? r.path : undefined;
        const decl = declaredChannels(path);
        if (decl === null) {
          undeclared++;
          warn(`${name} declares no channels.json — every branch in it reads as unstable (ADR-028 D11).`);
          warn(`  Add one at its root, or accept that this site cannot claim '${v}' for it.`);
          continue;
        }
        const want = decl[v] ?? [];
        if (br === undefined) continue;
        if (want.includes(br)) continue;            // already right
        disagree++;
        if (want.length === 0) {
          warn(`${name} declares no branch for channel '${v}' — it tracks '${br}' (${branchChannel(decl, br)}).`);
        } else {
          warn(`channel ${v} expects ${name} on '${want[0]}', but it tracks '${br}' (${branchChannel(decl, br)}).`);
          warn(`  Bring them together: site-manager repository modify ${name} --branch ${want[0]}`);
        }
      }
      if (undeclared > 0 || disagree > 0) {
        warn(`The channel is set to '${v}', but ${undeclared + disagree} repository/repositories do not yet match it.`);
      }
    };
    setChannel();

    setStr("--displayName", ["displayName"]);
    setStr("--owner", ["owner"]);
    setStr("--email", ["email"]);
    setBool("--automaticReboot", ["automaticReboot"]);
    setBool("--ipv6", ["ipv6"]);
    setBool("--requireSigned", ["requireSigned"]);
    setInt("--snapshotRetention", ["snapshotRetention"]);
    setStr("--backupTarget", ["backup", "target"]);
    setStr("--backupOffsite", ["backup", "offsite"]);
    // ADR-012 §3.2: the base of the Site → Environment → Module schedule
    // cascade. daily | weekly | monthly | HH:MM; nothing sub-daily.
    setStr("--backupDefaultSchedule", ["backup", "defaultSchedule"]);
    setStr("--backupDefaultRetention", ["backup", "defaultRetention"]);
    // The place fields are a location's (site-manager location modify); the
    // retired --location* spellings still reach the primary one — or, on a
    // site.json migration 0019 has not reached, the retired location itself.
    const { primary, legacy } = readLocations(raw);
    const placeAt = (field: string): string[] => (legacy || !primary ? ["location", field] : ["locations", primary, field]);
    const primaryFlag = o.flags.get("--primaryLocation");
    if (primaryFlag !== undefined) {
      const { locations } = readLocations(raw);
      if (legacy) die("site modify: --primaryLocation needs the locations migration 0019 makes first (it runs with the next update)");
      if (!locations[primaryFlag]) die(`site modify: --primaryLocation '${primaryFlag}' is not one of the site's locations (site-manager location list)`);
      if (!locations[primaryFlag].timezone) die(`site modify: '${primaryFlag}' records no timezone, and the primary location's is the site's: site-manager location modify ${primaryFlag} --timezone <tz>`);
    }
    setStr("--primaryLocation", ["primaryLocation"]);
    setStr("--locale", legacy ? ["location", "locale"] : ["locale"]);
    setStr("--keyboard", legacy ? ["location", "keyboard"] : ["keyboard"]);
    setStr("--locationLocale", legacy ? ["location", "locale"] : ["locale"]);
    setStr("--locationKeyboard", legacy ? ["location", "keyboard"] : ["keyboard"]);
    setStr("--locationCountry", placeAt("country"));
    setStr("--locationTimezone", placeAt("timezone"));
    setStr("--brandingLogo", ["branding", "logo"]);
    setStr("--brandingLogoDark", ["branding", "logoDark"]);
    setBool("--dnssec", ["dnssec"]);
    setList("--dnsBlocklistsLists", ["dnsBlocklists", "lists"]);
    setList("--dnsBlocklistsZones", ["dnsBlocklists", "zones"]);
    setList("--dnsBlocklistsAllow", ["dnsBlocklists", "allow"]);
    setBool("--diskAutoGrowEnabled", ["diskAutoGrow", "enabled"]);
    setRange("--diskAutoGrowThreshold", ["diskAutoGrow", "threshold"], 1, 100);
    setRange("--diskAutoGrowGrowPercent", ["diskAutoGrow", "growPercent"], 1, Infinity);
    setRange("--diskAutoGrowMinGrowGB", ["diskAutoGrow", "minGrowGB"], 1, Infinity);
    setRange("--diskAutoGrowPoolCeiling", ["diskAutoGrow", "poolCeiling"], 1, 100);
    setNum("--locationLatitude", placeAt("latitude"), -90, 90);
    setNum("--locationLongitude", placeAt("longitude"), -180, 180);
    setStr("--locationCity", placeAt("city"));
    setStr("--locationBuilding", placeAt(legacy ? "building" : "address"));
    setStr("--networkIsp", ["network", "isp"]);
    setStr("--networkPublicIp", ["network", "publicIp"]);

    // updateSchedule is a [frequency, weekday, hour] tuple, not a scalar. Edit it
    // by component so a partial change (e.g. only --updateFrequency daily) keeps
    // the rest. daily/none carry no weekday — normalised to null.
    const freq = o.flags.get("--updateFrequency");
    const wday = o.flags.get("--updateWeekday");
    const hour = o.flags.get("--updateHour");
    if (freq !== undefined || wday !== undefined || hour !== undefined) {
      const cur = readSchedule(raw.updateSchedule);
      let f: string = cur.frequency ?? "weekly";
      let d: string | null = cur.weekday ?? null;
      let h: number | undefined = cur.hour ?? 2;
      if (freq !== undefined) {
        const FREQS = ["daily", "weekly", "monthly", "none"];
        if (!FREQS.includes(freq)) die(`--updateFrequency must be one of: ${FREQS.join(", ")}`);
        f = freq;
      }
      if (wday !== undefined) {
        const DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
        if (!DAYS.includes(wday)) die(`--updateWeekday must be one of: ${DAYS.join(", ")}`);
        d = wday;
      }
      if (hour !== undefined) {
        const n = parseInt(hour, 10);
        if (!Number.isInteger(n) || n < 0 || n > 23) die("--updateHour must be an integer 0-23");
        h = n;
      }
      // daily/none run every day / never — a weekday would be meaningless.
      if (f === "daily" || f === "none") d = null;
      else if (d == null || d === "") die(`--updateWeekday is required for a '${f}' schedule`);
      // Written in the object form, always: a modify that put the triple back
      // on a migrated site would undo 0003, which the ledger says is done.
      setDeep(raw, ["updateSchedule"], writeSchedule(f, d, h));
      changed++;
    }

    if (changed === 0) die("site modify: no recognised --<field> given (see --help)");
    writeSite(siteFile, raw);
    info(`${GN}✓${CL} site.json updated (${changed} field(s)) — run 'validate' to confirm`);
    // ADR-017 D2: a new schedule takes effect now — re-render the timer. Only
    // for the site's own config, never for a --config-dir copy.
    if ((freq !== undefined || wday !== undefined || hour !== undefined) && o.configDir === defaultConfigDir()) {
      const r = spawnSync(process.env.SITE_SYSTEMCTL_BIN ?? "systemctl", ["start", "update-tappaas-schedule.service"], { encoding: "utf8" });
      if (r.status === 0) info("  update timer re-rendered from the new schedule");
      else warn("  could not re-render the update timer — it takes effect at the next boot or update (systemctl start update-tappaas-schedule.service)");
    }
    return;
  }

  die(`site ${sub}: unknown subcommand (expected 'show' | 'modify')`);
}

// Set raw[path...] = value, creating intermediate objects.
// updateSchedule in either shape (ADR-017 D7). The named object is what is
// written from here on; the legacy [frequency, weekday, hour] triple is still
// READ, because a restored backup or a site on an older release can hold one
// and a reader that refused it would take that site's updates away. Migration
// 0003 is what converts a site; this is what keeps the CLI honest until then.
//
// `weekday` comes back only where a reader honours it: under daily and none it
// was always inert, and showing it is how a site came to believe in a weekly
// update it was not getting (#447).
export function readSchedule(v: unknown): { frequency?: string; weekday?: string | null; hour?: number } {
  if (Array.isArray(v)) {
    const [f, d, h] = v as unknown[];
    const freq = typeof f === "string" ? f : undefined;
    const inert = freq === "daily" || freq === "none";
    return {
      frequency: freq,
      weekday: inert ? null : (typeof d === "string" ? d : null),
      hour: typeof h === "number" ? h : (typeof h === "string" && /^\d+$/.test(h) ? parseInt(h, 10) : undefined),
    };
  }
  if (v && typeof v === "object") {
    const o = v as Record<string, unknown>;
    const freq = typeof o.frequency === "string" ? o.frequency : undefined;
    const inert = freq === "daily" || freq === "none";
    return {
      frequency: freq,
      weekday: inert ? null : (typeof o.weekday === "string" ? o.weekday : null),
      hour: typeof o.hour === "number" ? o.hour : undefined,
    };
  }
  return {};
}

// The object a modify writes: no weekday under daily/none, no hour under none.
export function writeSchedule(f: string, d: string | null, h: number | undefined): Record<string, unknown> {
  const out: Record<string, unknown> = { frequency: f };
  if (f !== "daily" && f !== "none" && d) out.weekday = d;
  if (f !== "none") out.hour = h ?? 2;
  return out;
}

function setDeep(obj: Record<string, unknown>, path: string[], value: unknown): void {
  let cur = obj;
  for (let i = 0; i < path.length - 1; i++) {
    const k = path[i];
    if (typeof cur[k] !== "object" || cur[k] === null) cur[k] = {};
    cur = cur[k] as Record<string, unknown>;
  }
  cur[path[path.length - 1]] = value;
}

// ── `node` CRUD + reconcile (hardware.nodes[]) ─────────────────────────
function cmdNode(o: Opts, client: SiteClient): void {
  const sub = o.rest[0];
  if (!sub) die("node: expected 'list' | 'add' | 'delete' | 'reconcile' | 'reboot'");
  const siteFile = siteFileOf(o);

  if (sub === "reconcile") {
    // Capture cluster membership into site.json (docs/design/
    // node-provisioning.md N1): the scoped node slice of `reconcile`, exactly
    // as `repository reconcile` is the repo slice.
    const site: Site = loadSite(siteFile);
    const plan = computePlan(site, client, {
      deep: false,
      apply: o.apply,
      siteFile,
      scope: "nodes",
    });
    printPlan(plan, o.apply);
    if (o.apply && plan.actions.length > 0) {
      const res = applyPlan(client, plan);
      info("");
      for (const f of res.failures) warn(`${f.target} failed: ${f.error}`);
      info(`${GN}Applied ${res.applied} action(s) — declare storage pools for new nodes before installing modules on them.${CL}`);
    }
    return;
  }

  if (sub === "list") {
    const site: Site = loadSite(siteFile);
    if (o.json) {
      info(JSON.stringify(site.hardware.nodes, null, 2));
    } else if (site.hardware.nodes.length === 0) {
      info("(no nodes)");
    } else {
      for (const n of site.hardware.nodes) {
        info(`${n.name}\t[${n.storagePools.join(", ")}]`);
      }
    }
    return;
  }

  if (sub === "add") {
    const name = o.flags.get("--name") ?? o.rest[1];
    if (!name) die("node add: expected --name <N> (or positional name)");
    if (!/^[A-Za-z0-9_-]+$/.test(name)) die(`node add: invalid name '${name}'`);
    // --pool may be given multiple times; parseOpts keeps only the last, so we
    // also accept trailing positionals after the name as pools.
    const pools = collectPools(o, name);
    if (o.boolFlags.has("--config-only")) {
      // Just declare the node in site.json (no machine contact).
      const raw = loadRaw(siteFile);
      if (Object.keys(raw).length === 0) die(`site.json not found: ${siteFile}`);
      const hw = (raw.hardware ?? (raw.hardware = {})) as Record<string, unknown>;
      const nodes = (Array.isArray(hw.nodes) ? hw.nodes : (hw.nodes = [])) as SiteNode[];
      if (nodes.some((n) => n.name === name)) die(`node '${name}' already exists`);
      nodes.push({ name, storagePools: pools });
      writeSite(siteFile, raw);
      info(`${GN}✓${CL} node '${name}' added (pools: ${pools.join(", ") || "none"})`);
      return;
    }
    if (o.boolFlags.has("--provision")) {
      warn("--provision is deprecated — use --pxe");
    }
    const opts = {
      name,
      bootDisk: o.flags.get("--boot-disk"),
      macs: o.flags.get("--mac") ? [o.flags.get("--mac") as string] : [],
      pools,
      wanPort: o.boolFlags.has("--no-wan") ? "" : o.flags.get("--wan-port"),
      lanPorts: o.flags.get("--lan-ports"),
      lanMode: o.flags.get("--lan-mode"),
      lanPrimary: o.flags.get("--lan-primary"),
      ttlSeconds: Number(o.flags.get("--ttl") ?? 7200),
      yes: o.boolFlags.has("--yes"),
    };
    if (o.boolFlags.has("--pxe") || o.boolFlags.has("--provision")) {
      // Bare machine: PXE install → join → capture (design N3).
      provisionNode(opts);
    } else {
      // Default: a Proxmox was installed by hand at the node's designated
      // mgmt IP — verify and run the join pipeline over ssh.
      adoptNode(opts);
    }
    return;
  }

  if (sub === "delete") {
    const name = o.rest[1];
    if (!name) die("node delete: expected <name>");
    const raw = loadRaw(siteFile);
    const hw = (raw.hardware ?? {}) as Record<string, unknown>;
    const nodes = (Array.isArray(hw.nodes) ? hw.nodes : []) as SiteNode[];
    const inSite = nodes.some((n) => n.name === name);
    const dropFromSite = (): void => {
      if (!inSite) return;
      hw.nodes = nodes.filter((n) => n.name !== name);
      raw.hardware = hw;
      writeSite(siteFile, raw);
      info(`${GN}✓${CL} node '${name}' dropped from site.json`);
    };

    if (o.boolFlags.has("--config-only")) {
      if (!inSite) die(`node '${name}' not found`);
      dropFromSite();
      unregisterNodeModule(name, o.configDir);
      return;
    }

    // The cluster side is the cluster module's (#417), as reboot is: preview by
    // default, --execute only with --apply, and the script asks for the node
    // name — and for ERASE — on the operator's terminal.
    const script = clusterScript("remove-node.sh");
    if (!script) die("remove-node.sh not found — is the cluster module installed? (module-manager show cluster)");
    const args = [o.apply ? "--execute" : "--dry-run"];
    if (o.boolFlags.has("--shutdown")) args.push("--shutdown");
    if (o.boolFlags.has("--erase")) args.push("--erase");
    args.push(name);
    info(`${o.apply ? "" : "[preview] "}node delete '${name}' → ${script} ${args.join(" ")}`);
    const r = spawnSync(script, args, { stdio: "inherit" });
    const rc = r.status ?? -1;
    if (rc !== 0) die(`remove-node.sh exited ${rc} — site.json and the node's module are unchanged`);
    if (!o.apply) {
      if (inSite) info(`  then: '${name}' is dropped from site.json and its pvehost module archived`);
      return;
    }
    dropFromSite();
    unregisterNodeModule(name, o.configDir);
    // A node rebuilt under this name brings a new host key: no stale pin here.
    for (const h of [name, `${name}.mgmt.internal`]) spawnSync("ssh-keygen", ["-R", h], { stdio: "ignore" });
    return;
  }

  if (sub === "reboot") {
    const name = o.rest[1];
    if (!name) die("node reboot: expected <name>");

    // Refuse a node this site does not own, rather than letting the script
    // discover it later: site.json is the register of what belongs here, and a
    // typo should not reach a command that drains HA services.
    const raw = loadRaw(siteFile);
    const hw = (raw.hardware ?? {}) as Record<string, unknown>;
    const nodes = (Array.isArray(hw.nodes) ? hw.nodes : []) as SiteNode[];
    if (!nodes.some((n) => n.name === name)) {
      die(`node '${name}' not found in ${siteFile} (site-manager node list)`);
    }

    const script = clusterScript("reboot-node.sh");
    if (!script) {
      die("reboot-node.sh not found — is the cluster module installed? (module-manager show cluster)");
    }

    // --apply maps to the script's --execute; anything else previews. The
    // script's own default is --dry-run, and so is ours: a reboot drains HA
    // services off a node, which is not something to do by omission.
    // o.apply, not o.flags: the parser lifts --apply into a dedicated boolean
    // (same field `node reconcile` and `site reconcile` read), so it never
    // appears in the generic flags map.
    const apply = o.apply;
    const mode = apply ? "--execute" : "--dry-run";
    info(`${apply ? "" : "[preview] "}node reboot '${name}' → ${script} ${mode}`);

    // stdio inherit: the operator watches the drain/reboot/failback live, and
    // --execute prompts for confirmation in the script itself.
    const r = spawnSync(script, [mode, name], { stdio: "inherit" });
    const rc = r.status ?? -1;
    if (rc !== 0) die(`reboot-node.sh exited ${rc}`);
    return;
  }

  if (sub === "qdevice") {
    const action = o.rest[1];
    if (!["add", "remove", "status"].includes(action ?? "")) die("node qdevice: add <host> | remove | status");
    const script = clusterScript("qdevice.sh");
    if (!script) die("qdevice.sh not found — is the cluster module installed? (module-manager show cluster)");
    const args = [action as string];
    if (action === "add") {
      const host = o.rest[2];
      if (!host) die("node qdevice add <host>");
      args.push(host);
      if (o.force) args.push("--force");
    }
    const user = o.flags.get("--user");
    if (user && action !== "status") args.push("--user", user);
    const r = spawnSync(script, args, { stdio: "inherit" });
    const rc = r.status ?? -1;
    if (rc !== 0) die(`qdevice.sh exited ${rc}`);
    return;
  }

  if (sub === "network") {
    // #40: the lan uplink is the cluster module's (lan-uplink.sh), as qdevice is.
    const action = o.rest[1];
    const node = o.rest[2];
    if (!["show", "set", "test"].includes(action ?? "")) die("node network: show | set | test <node>");
    if (!node) die(`node network ${action}: expected <node>`);
    const script = clusterScript("lan-uplink.sh");
    if (!script) die("lan-uplink.sh not found — is the cluster module installed? (module-manager show cluster)");
    const args = [action as string, node];
    if (action === "show" && o.json) args.push("--json");
    if (action === "set") {
      for (const f of ["--lan-ports", "--lan-mode", "--lan-primary", "--mtu", "--switch-wait", "--wan-port"]) {
        const v = o.flags.get(f);
        if (v) args.push(f, v);
      }
      if (o.boolFlags.has("--config-only")) args.push("--config-only");
      if (o.boolFlags.has("--no-wan")) args.push("--no-wan");
      if (o.boolFlags.has("--no-wan") && o.flags.get("--wan-port")) die("node network set: --no-wan and --wan-port are each other's opposite — give one");
    }
    if (action !== "show") {
      args.push(o.apply ? "--execute" : "--dry-run");
      if (o.boolFlags.has("--yes")) args.push("--yes");
    }
    const r = spawnSync(script, args, { stdio: "inherit" });
    const rc = r.status ?? -1;
    if (rc !== 0) process.exit(rc > 0 ? rc : 1);
    return;
  }

  die(`node ${sub}: unknown subcommand`);
}

function collectPools(o: Opts, name: string): string[] {
  const pools: string[] = [];
  const single = o.flags.get("--pool");
  if (single) pools.push(single);
  // positionals after the node name (rest[0]=node, rest[1]=name?) are pools.
  for (const r of o.rest.slice(1)) {
    if (r !== name) pools.push(r);
  }
  return Array.from(new Set(pools));
}

// ── `repository` CRUD + reconcile ──────────────────────────────────────
function cmdRepository(o: Opts, client: SiteClient): void {
  const sub = o.rest[0];
  if (!sub) die("repository: expected 'list' | 'add' | 'introduce' | 'modify' | 'delete' | 'reconcile' | 'sync' | 'hold' | 'release' | 'stash'");
  const siteFile = siteFileOf(o);

  if (sub === "list") {
    const site = loadSite(siteFile);
    if (o.json) {
      info(JSON.stringify(site.repositories, null, 2));
    } else if (site.repositories.length === 0) {
      info("(no repositories)");
    } else {
      const holds = readHolds(o.configDir);
      const now = Math.floor(Date.now() / 1000);
      for (const r of site.repositories) {
        const h = holds.get(r.name);
        info(`${r.name}\t${r.url}\t${r.branch ?? "stable"}\t${r.managed ?? "full"}${h ? `\t${describeHold(h, now)}` : ""}`);
      }
    }
    return;
  }

  // Rebuild "--key value" pairs from parsed flags for the bash delegations
  // (parseOpts captures valued flags into o.flags, so o.rest holds positionals
  // only — forwarding o.rest alone would silently drop --url/--branch/etc.).
  const fwdFlags = (keys: string[]): string[] => {
    const out: string[] = [];
    for (const k of keys) {
      const v = o.flags.get(k);
      if (v !== undefined) out.push(k, v);
    }
    return out;
  };

  if (sub === "stash") {
    // #681: what a sync had to set aside stays discoverable through the
    // sanctioned surface, not only through `git stash list` in a checkout the
    // operator is told not to edit. --force is a flag, so forward it explicitly.
    const rest = o.rest.slice(1);
    if (o.force) rest.push("--force");
    process.exit(client.repositoryStash(rest));
  }

  if (sub === "sync") {
    // #814: one repository to its branch tip, with the sweep's guards and
    // without the sweep. repository.sh owns it — the repo-sync, hold and
    // migration-ledger code it needs is bash. One name only: the whole site is
    // `site-manager update`, which also runs the migrations.
    const rest = o.rest.slice(1);
    if (rest.length !== 1) die("repository sync: expected exactly one <name> (every repository: site-manager update)");
    if (o.boolFlags.has("--dry-run")) rest.push("--dry-run");
    const rc = client.repositorySync(rest);
    if (rc !== 0) throw new DieError(`repository sync ${rest[0]}: not synced (repository.sh exited ${rc})`);
    return;
  }

  if (sub === "validate-catalog") {
    // #463: the check lives beside repository.sh, which owns every catalog path.
    const rest = o.rest.slice(1);
    if (o.flags.has("--strict")) rest.push("--strict");
    process.exit(client.repositoryValidateCatalog(rest));
  }

  if (sub === "add") {
    // Thin delegation: repository.sh still owns URL validation, git clone +
    // checkout, catalog validation, and the VMID/name conflict scan, and writes
    // the site.json .repositories entry. Forward <url> + its valued flags.
    const url = o.rest[1];
    if (!url) die("repository add: expected <url>");
    const args = [url, ...fwdFlags(["--branch", "--managed", "--catalog", "--introduction", "--signer"])];
    if (o.boolFlags.has("--unsigned")) args.push("--unsigned");
    const rc = client.repositoryAdd(args);
    if (rc !== 0) throw new DieError(`repository.sh add exited ${rc}`);
    return;
  }

  if (sub === "introduce") {
    const name = o.rest[1];
    if (!name) die("repository introduce: expected <name> [--introduction <tag> --signer SHA256:<fp>]");
    const rc = client.repositoryIntroduce([name, ...fwdFlags(["--introduction", "--signer"])]);
    if (rc !== 0) throw new DieError(`repository introduce ${name}: not verified (repository.sh exited ${rc})`);
    return;
  }

  if (sub === "modify") {
    const name = o.rest[1];
    if (!name) die("repository modify: expected <name> [--url <url>] [--branch <branch>]");
    // Thin delegation: repository.sh modify re-points origin (forge migration:
    // github.com -> codeberg.org) and/or switches branch on the live checkout,
    // then edits site.json. Forward <name> + --url/--branch.
    const flags = fwdFlags(["--url", "--branch"]);
    if (flags.length === 0) die("repository modify: expected --url and/or --branch");
    const rc = client.repositoryModify([name, ...flags]);
    if (rc !== 0) throw new DieError(`repository.sh modify exited ${rc}`);
    return;
  }

  if (sub === "delete") {
    const name = o.rest[1];
    if (!name) die("repository delete: expected <name>");
    // Thin delegation: repository.sh remove checks installed-module dependents,
    // rm -rf's the clone, and edits site.json. --force forwards through.
    const rc = client.repositoryRemove(name, o.force);
    if (rc !== 0) throw new DieError(`repository.sh remove exited ${rc}`);
    return;
  }

  if (sub === "hold") {
    const name = o.rest[1];
    const reason = o.flags.get("--reason");
    if (!name || !reason) die("repository hold: expected <name> --reason <text> [--until <when>]");
    if (!validRepoName(name)) die(`repository hold: '${name}' is not a repository name`);
    const site = loadSite(siteFile);
    if (!site.repositories.some((r) => r.name === name)) {
      die(`repository hold: '${name}' is not a repository in ${siteFile}`);
    }
    const now = Math.floor(Date.now() / 1000);
    let until: number;
    try {
      until = parseUntil(o.flags.get("--until") ?? DEFAULT_HOLD, now);
    } catch (e) {
      die((e as Error).message);
    }
    const by = process.env.SUDO_USER || process.env.USER || "unknown";
    const h = makeHold(name, reason, by, until!, now);
    const f = writeHold(o.configDir, h);
    info(`${name}: ${describeHold(h, now)}`);
    info(`  marker: ${f} — release early with: site-manager repository release ${name}`);
    return;
  }

  if (sub === "release") {
    const name = o.rest[1];
    if (!name) die("repository release: expected <name>");
    if (!validRepoName(name)) die(`repository release: '${name}' is not a repository name`);
    info(releaseHold(o.configDir, name)
      ? `${name}: hold released — the next sweep pulls it again`
      : `${name}: no hold`);
    return;
  }

  if (sub === "reconcile") {
    // repository reconcile = converge repositories[] to live clones (the (1)
    // own-concern half of `reconcile`, scoped to repos). Reuses the engine with
    // deep=false; we still emit only the repo actions. Descriptive per-repo
    // output so the operator sees WHAT was checked, not just an action count.
    const site = loadSite(siteFile);
    const plan = computePlan(site, client, {
      deep: false,
      apply: o.apply,
      siteFile,
      scope: "repositories",
    });
    info("");
    info(
      `Reconciling ${site.repositories.length} repository(ies) from site.json → live git clones` +
        `${o.apply ? "" : " (preview)"}:`,
    );
    for (const w of plan.warnings) warn(w);
    // #814: present and on its branch is not up to date. Say how far behind
    // origin each checkout is (ls-remote; nothing is fetched or moved).
    let behindAny = 0;
    for (const repo of site.repositories) {
      const br = repo.branch ?? "stable";
      const act = plan.actions.find((a) => a.target.startsWith(`repository ${repo.name} `));
      if (!act) {
        const p = client.repoProbe(repo.path ?? `/home/tappaas/${repo.name}`, br);
        if (p.head && p.tip && p.head !== p.tip) {
          behindAny++;
          info(`  ${YW}↓${CL} ${repoStatusLine(repo.name, br, p.head, p.tip, p.behind, null)} — site-manager repository sync ${repo.name}`);
        } else {
          info(`  ${GN}✓${CL} ${repo.name} @ ${br} — present, on the declared branch${p.head && p.tip ? ", current" : ""}`);
        }
      } else if (act.kind === "clone-repo") {
        info(`  ${YW}+${CL} ${repo.name} @ ${br} — ${o.apply ? "cloning" : "not cloned; would clone"} ${repo.url}`);
      } else {
        // checkout-repo target: "repository <name> → checkout <branch> (was <cur>)"
        const detail = act.target.replace(`repository ${repo.name} → `, "");
        info(`  ${YW}⟳${CL} ${repo.name} — ${o.apply ? "" : "would "}${detail}`);
      }
    }
    info("");
    if (plan.actions.length === 0 && behindAny > 0) {
      info(`${YW}Every repository is present and on its declared branch; ${behindAny} is behind origin (sync it, or wait for the sweep).${CL}`);
    } else if (plan.actions.length === 0) {
      info(`${GN}Converged — every repository is present and on its declared branch. Nothing to do.${CL}`);
    } else if (o.apply) {
      const res = applyPlan(client, plan);
      for (const f of res.failures) warn(`${f.target} failed: ${f.error}`);
      info(`${GN}Applied ${res.applied} action(s).${CL}`);
    } else {
      info(`${plan.actions.length} change(s) needed — re-run with --apply to perform them.`);
    }
    return;
  }

  die(`repository ${sub}: unknown subcommand`);
}

// ── top-level lifecycle verbs ──────────────────────────────────────────

// `validate` — validate site.json (= validate-site.sh).
// evacuate <node> — clear a node for maintenance (ADR-019 scenario C).
// The orchestration itself is in src/evacuate.ts so it is testable without a
// cluster; this is the CLI shell around it.
function cmdEvacuate(o: Opts, client: SiteClient): number {
  const node = o.rest[0];
  if (!node) die("evacuate: expected <node>");

  const r = evacuateNode(node, client, o.force === true);
  if (r.unreachable) {
    warn(`${RD}Could not ask the cluster what runs on ${node} — is it reachable?${CL}`);
    return 1;
  }
  if (r.considered.length === 0) {
    info(`${node} has no guests — nothing to evacuate.`);
    return 0;
  }

  info(`Evacuated ${r.moved.length}/${r.considered.length} guest(s) from ${node}`);
  if (r.deferred.length > 0) {
    warn(`Still on ${node}, needing downtime you have not authorized: ${r.deferred.join(", ")}`);
    warn(`Re-run with --force to move them offline (they will stop and restart).`);
  }
  if (r.failed.length > 0) {
    warn(`${RD}Failed to move: ${r.failed.join(", ")}${CL}`);
  }
  if (r.deferred.length === 0 && r.failed.length === 0) info(`${GN}${node} is clear.${CL}`);
  return evacuateExitCode(r);
}

function cmdValidate(o: Opts, client: SiteClient): void {
  const siteFile = o.rest[0] ?? siteFileOf(o);
  const errs = client.validateSite(siteFile);
  // What the schema cannot say (ADR-036 D1): the primary location exists and
  // has the site's timezone, and every location something names exists. The
  // names are looked for beside the site.json validated.
  if (existsSync(siteFile)) {
    try {
      errs.push(...locationErrors(loadRaw(siteFile), dirname(siteFile)));
    } catch {
      // not JSON: validate-site.sh has said so
    }
  }
  if (errs.length === 0) {
    info(`${GN}✓${CL} site.json valid: ${siteFile}`);
    return;
  }
  for (const e of errs) console.error(`${RD}[Error]${CL} VALIDATION: ${e}`);
  die(`site.json has ${errs.length} validation error(s)`);
}

// `reconcile` — converge site config → live (+ --deep cascade). Returns the
// exit code: 1 when any action (notably a cascade) failed to converge.
function cmdReconcile(o: Opts, client: SiteClient): number {
  const siteFile = siteFileOf(o);
  const site = loadSite(siteFile);
  const plan = computePlan(site, client, { deep: o.deep, apply: o.apply, siteFile });
  printPlan(plan, o.apply);
  if (!o.apply || plan.actions.length === 0) return 0;

  const res = applyPlan(client, plan);
  info("");
  // A cascade that ran and failed is named here rather than swallowed: the
  // whole point is that `Applied N action(s)` must stop being printed over a
  // run where nothing converged.
  for (const f of res.failures) warn(`${f.target} failed: ${f.error}`);
  if (res.failures.length > 0) {
    info(
      `${RD}Applied ${res.applied} action(s); ${res.failures.length} failed.${CL}`,
    );
    return 1;
  }
  info(`${GN}Applied ${res.applied} action(s).${CL}`);
  return 0;
}

function printPlan(plan: { actions: { kind: string; target: string }[]; warnings: string[] }, apply: boolean): void {
  info("");
  info(`Plan: ${plan.actions.length} action(s), ${plan.warnings.length} warning(s)`);
  for (const w of plan.warnings) warn(w);
  for (const a of plan.actions) info(`  ${apply ? "" : "[preview] would "}${a.kind}: ${a.target}`);
  if (!apply) {
    info("");
    info("(preview — pass --apply to commit)");
  } else if (plan.actions.length === 0) {
    info(`${GN}Nothing to do — already converged.${CL}`);
  }
}

// `update` — run the whole-site update now (#588) by starting update-tappaas.service,
// the unit the timer starts too (ADR-017 D4), and following its journal. The
// options travel in a one-shot request (unitrun.ts): --force updates every module
// even when its pre-update test fails and opens the disruption window for
// rebootOk modules only (ADR-020 D8); --no-git-pull runs on whatever is checked
// out. --dry-run starts nothing: repository drift, then the sweep's plan.
function cmdUpdate(o: Opts, client: SiteClient): number {
  const dryRun = o.boolFlags.has("--dry-run");
  const noGitPull = o.boolFlags.has("--no-git-pull");
  const force = o.force === true;
  const allowDisruption = o.boolFlags.has("--allow-disruption");
  const nowSec = Math.floor(Date.now() / 1000);
  const holds = readHolds(o.configDir);

  if (dryRun) {
    // ADR-017 D4: starts nothing. Where each repository stands against its
    // origin, then the sweep's plan.
    const site = loadSite(siteFileOf(o));
    info("Repositories:");
    for (const r of site.repositories) {
      const branch = r.branch ?? "stable";
      const h = holds.get(r.name);
      const hold = h ? describeHold(h, nowSec) : null;
      const p = hold ? { head: null, tip: null, behind: null } : client.repoProbe(r.path ?? `/home/tappaas/${r.name}`, branch);
      info(`  ${repoStatusLine(r.name, branch, p.head, p.tip, p.behind, hold)}`);
    }
    return client.runUpdateDryRun(force, allowDisruption);
  }

  for (const h of holds.values()) info(`${YW}${h.repository}: ${describeHold(h, nowSec)}${CL}`);
  if (force) {
    warn(`${YW}--force: every module updates even if its pre-update test failed fatally.${CL}`);
  }
  if (allowDisruption) {
    warn(`${YW}--allow-disruption: modules with rebootOk may be rebooted or migrated offline now; the others keep disruptive changes deferred.${CL}`);
  }
  const state = client.unitState();
  if (state === "active" || state === "activating" || state === "deactivating") {
    die(`${UNIT} is already running (${state}) — follow it: journalctl -fu ${UNIT}`);
  }
  const by = process.env.SUDO_USER || process.env.USER || "unknown";
  writeRequest(o.configDir, buildRequest(force, allowDisruption, noGitPull, by, new Date()));
  const started = client.startUnit();
  if (!started.ok) {
    dropRequest(o.configDir);
    die(`could not start ${UNIT}: ${started.err}`);
  }
  infoTagged(`started ${UNIT} (this run continues if you detach — Ctrl-C only stops following)`);
  debug(`follow:   journalctl -fu ${UNIT}`);
  debug(`status:   systemctl status ${UNIT}`);
  if (client.followUnit(started.invocationId) === "detached") {
    infoTagged(`detached — the run continues: journalctl -fu ${UNIT}`);
    return 0;
  }
  const result = client.unitResult();
  // On success update-tappaas's own last line, just followed, is this summary.
  if (result !== "success") {
    infoTagged(summaryLine(readResult(o.configDir)));
    warn(`${UNIT} ended with result '${result}' — journalctl -u ${UNIT} -n 200; the site owner was notified (#651)`);
    return 1;
  }
  debug("verify:   jq .ok ~/config/last-update-result.json     → true");
  debug("verify:   site-manager update --dry-run               → no repository drift remains");
  return 0;
}

// Modules with NO live lifecycle — decommissioned, their VM is gone — mirror
// update-tappaas's NON_LIFECYCLE_STATUSES (#441). Testing them always fails
// (dependency-service checks hit an absent VM), so they are skipped, not run.
const NON_LIFECYCLE_STATUSES = new Set(["archived", "external"]);

// `test` — run every deployed module's tests (#588). Iterates the module-manager
// module list (foundation + apps, from every registered repository), SKIPPING
// decommissioned (archived/external) modules, and runs `module-manager test
// <m>`, forwarding --deep. Continue-on-failure: one module's failure never stops
// the run; the summary + exit code report it.
function cmdTest(o: Opts, client: SiteClient): number {
  const all = client.listDeployedModules();
  if (all === null) {
    warn(`${RD}Could not list deployed modules (module-manager list --json failed).${CL}`);
    return 1;
  }
  const isDecommissioned = (m: { status: string }): boolean =>
    NON_LIFECYCLE_STATUSES.has(m.status.trim().toLowerCase());
  const skipped = all.filter(isDecommissioned);
  const names = all.filter((m) => !isDecommissioned(m)).map((m) => m.name);
  if (skipped.length > 0) {
    info(`Skipping ${skipped.length} decommissioned module(s): ${skipped.map((m) => `${m.name} (${m.status})`).join(", ")}`);
  }
  if (names.length === 0) {
    info("No deployed modules to test.");
    return 0;
  }
  const deep = o.deep === true;
  info(`Testing ${names.length} module(s)${deep ? " (deep)" : ""}: ${names.join(", ")}`);
  const failed: string[] = [];
  for (const name of names) {
    info("");
    info(`${GN}== test ${name}${deep ? " --deep" : ""} ==${CL}`);
    if (client.testModule(name, deep) !== 0) failed.push(name);
  }
  info("");
  if (failed.length > 0) {
    warn(`${RD}${failed.length}/${names.length} module test(s) FAILED: ${failed.join(", ")}${CL}`);
    return 1;
  }
  info(`${GN}✓ All ${names.length} module test(s) passed.${CL}`);
  return 0;
}

// `add` — create the site singleton (= create-site.sh). Thin delegation: the
// cluster-discovery write (ssh pvesh node/pool discovery, tz/locale detection,
// version-from-git, Proxmox email discovery, force-preserve-on-rerun) stays in
// create-site.sh. We forward the args verbatim so its full flag set
// (--name/--organization/--domain/--branch/--upstream-git/--email/--primary-node/
// --schedule/--weekday/--hour/--config-dir/--force) keeps working unchanged.
function cmdAdd(args: string[], client: SiteClient): void {
  const rc = client.createSite(args);
  if (rc !== 0) throw new DieError(`create-site.sh exited ${rc}`);
}

// ── dispatch ───────────────────────────────────────────────────────────
export function run(argv: string[], client: SiteClient): number {
  if (argv.length === 0) {
    usage();
    return 0;
  }
  const args = argv[0] === "repo" ? ["repository", ...argv.slice(1)] : argv;
  // #644: --help in any position prints help and runs nothing (`update --help`
  // used to start the sweep); an option the verb does not take is refused.
  const gate = checkArgs(HELP, args);
  if (gate !== undefined) return gate;
  const cmd = args[0];
  const o = parseOpts(args.slice(1));

  return guarded(() => {
    preflightGuard(); // #533: refuse root; self-heal config/repo ownership
    switch (cmd) {
      case "site":
        cmdSite(o);
        return 0;
      case "node":
        cmdNode(o, client);
        return 0;
      case "repository":
        cmdRepository(o, client);
        return 0;
      case "add":
        // create-site.sh has its own flag set — forward raw args, not parsed.
        cmdAdd(args.slice(1), client);
        return 0;
      case "evacuate":
        return cmdEvacuate(o, client);
      case "validate":
        cmdValidate(o, client);
        return 0;
      case "reconcile":
        return cmdReconcile(o, client);
      case "update":
        return cmdUpdate(o, client);
      case "test":
        return cmdTest(o, client);
      default:
        usage();
        die(`Unknown command: ${cmd}`);
    }
  });
}

// Entry point (only when run directly, not when imported by tests).
if (require.main === module) {
  const client = new CliSiteClient();
  // exitCode, not exit(): exit() ends the process before a large write to a pipe
  // has drained, cutting --json output at 65536 bytes (found with health-manager, #788).
  process.exitCode = run(process.argv.slice(2), client);
}
