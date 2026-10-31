// noderemove.ts — what the Remove a node wizard reads (pages/RemoveNode.tsx):
// the check (site-manager node delete <node> --<how>, its dry run) turned into
// findings in the operator's words, each with where to act; and the removal's
// output turned into what is now true. Pure: the wizard runs the jobs, this
// reads their text.


export type How = "shutdown" | "erase" | "lost";
export type AssetChoice = "keep" | "remove";

export const HOWS: { id: How; label: string; detail: string }[] = [
  { id: "shutdown", label: "power it off, then remove it", detail: "The usual way: the cluster lets a node go only once it is off. Its disks keep their data." },
  { id: "erase", label: "wipe its disks, power it off, then remove it", detail: "Every disk is wiped, the boot disk too: the machine keeps nothing. For a machine that leaves the building." },
  { id: "lost", label: "it is down for good", detail: "A dead machine: what still ran on it is lost with it and is restored from backup elsewhere; its settings are saved first." },
];

export const ASSET_CHOICES: { id: AssetChoice; label: string; detail: string }[] = [
  { id: "keep", label: "keep the machine's record", detail: "It goes back to stock; its place in the rack and its cables stay recorded, ready for its next role." },
  { id: "remove", label: "remove the machine's record", detail: "Its record, place and cables are removed: the machine leaves the site." },
];

export const checkArgv = (node: string, how: How): string[] => ["site-manager", "node", "delete", node, `--${how}`];
export const removeArgv = (node: string, how: How, asset: AssetChoice): string[] => [...checkArgv(node, how), "--asset", asset, "--yes", "--apply"];
// A lost machine is gone for good: its record goes, no question asked.
export const assetFor = (how: How, chosen: AssetChoice): AssetChoice => (how === "lost" ? "remove" : chosen);

// Where an operator acts on a finding.
export interface Target {
  to: string;
  label: string;
}
export const moduleTarget = (m: string, label = m): Target => ({ to: `/modules/${encodeURIComponent(m)}`, label });
export const BACKUP_TARGET: Target = { to: "/backup", label: "the Backup page" };
export const assetTarget = (key: string): Target => ({ to: `/assets/${encodeURIComponent(key)}`, label: key });
// A switch is shown, selected, in the Physical view.
export const switchTarget = (sw: string): Target => ({ to: `/site/physical?select=${encodeURIComponent(sw)}`, label: sw });

export interface Finding {
  text: string;
  target?: Target;
  hint?: string; // what to do there
}

export interface SwitchPort {
  sw: string;
  port: string;
}

export interface CheckOutcome {
  state: "running" | "ok" | "blocked" | "failed";
  blockers: Finding[]; // what stops the removal
  losses: Finding[]; // a lost node: what goes with it
  ports: SwitchPort[]; // the switch ports that will be parked
  asset: { key: string; fate: "kept" | "removed"; where: string | null } | null;
  record: "deleted" | "archived" | null;
  tail: string[]; // the last lines, for a failure
}

// The lines of a job's output: colour codes and the bash helpers' tags gone.
export function outputLines(text: string): string[] {
  return text
    .replace(/\x1b\[[0-9;]*[A-Za-z]/g, "")
    .split("\n")
    .map((l) => l.replace(/^\s*\[(Info|Warning|Error|Fatal|Debug)\]\s*/, "").trim())
    .filter((l) => l.length > 0);
}

const guestWord = (type: string): string => (type === "lxc" ? "container" : "VM");
const tail = (lines: string[], n = 8): string[] => lines.slice(-n);

// The check's output: blockers and, for a lost node, what is lost with it.
export function parseCheck(output: string, node: string, done: { exit: number | null } | null): CheckOutcome {
  const lines = outputLines(output);
  const blockers: Finding[] = [];
  const losses: Finding[] = [];
  const ports: SwitchPort[] = [];
  let asset: CheckOutcome["asset"] = null;
  let record: CheckOutcome["record"] = null;
  for (const l of lines) {
    let m: RegExpMatchArray | null;
    if ((m = l.match(/^✗ (qemu|lxc) (\d+) \((.*?)\) runs here — move it: module-manager modify (\S+) /))) {
      blockers.push({ text: `The ${guestWord(m[1])} ${m[3]} (${m[2]}) runs on ${node}.`, target: moduleTarget(m[4], `the module ${m[4]}`), hint: "move it to another node" });
    } else if ((m = l.match(/^✗ (qemu|lxc) (\d+) \((.*?)\) runs here and is no module's/))) {
      blockers.push({ text: `The ${guestWord(m[1])} ${m[3]} (${m[2]}) runs on ${node} and belongs to no module: move it to another node or remove it in Proxmox.` });
    } else if ((m = l.match(/^✗ replication job (\S+) (\S+)->(\S+?)(?: \(module (\S+)\))? —/))) {
      const what = m[4] ? `The module ${m[4]}'s` : `A guest's (replication job ${m[1]})`;
      blockers.push({ text: `${what} copy is replicated ${m[2] === node ? "from" : "to"} ${node}.`, target: m[4] ? moduleTarget(m[4], `the module ${m[4]}`) : undefined, hint: "give it a standby node other than this one" });
    } else if ((m = l.match(/^✗ HA rule (\S+) names it/))) {
      const mod = m[1].replace(/^ha-/, "");
      blockers.push({ text: `The module ${mod} may run on ${node} when another node fails.`, target: moduleTarget(mod, `the module ${mod}`), hint: "give it nodes other than this one" });
    } else if (/^✗ the site's PBS/.test(l)) {
      blockers.push({ text: `The site's backup server runs on ${node}.`, target: BACKUP_TARGET, hint: "move it to another node first" });
    } else if (/^✗ \S+ is running — Proxmox removes a node only once it is off/.test(l)) {
      blockers.push({ text: `${node} is still running: the cluster lets it go only once it is off. Choose to power it off first.` });
    } else if (/ is down: if it is gone for good, --lost removes it/.test(l)) {
      blockers.push({ text: `${node} does not answer. If it is gone for good, choose "it is down for good".` });
    } else if (/^--lost is for a node that is down/.test(l)) {
      blockers.push({ text: `${node} still answers: it is not down for good. Choose to power it off first, once what runs on it has moved.` });
    } else if (/^--erase needs the node running/.test(l)) {
      blockers.push({ text: `${node} does not answer, so its disks cannot be wiped. Start it, or choose "it is down for good" if it is gone.` });
    } else if (/^no other node answers/.test(l)) {
      blockers.push({ text: `No other node answers: the cluster cannot let ${node} go now.` });
    } else if (/^cannot list the cluster's guests/.test(l)) {
      blockers.push({ text: "The cluster's guests could not be listed. Check again in a moment." });
    } else if (/^remove-node\.sh not found/.test(l)) {
      blockers.push({ text: "The cluster's own tools are not installed on the mothership, so no node can be removed from here." });
    } else if ((m = l.match(/^(qemu|lxc) (\d+) \((.*?)\) is lost with the node — restore it from backup: backup-manager restore restore (\S+)/))) {
      const mod = m[4].startsWith("<") ? null : m[4];
      losses.push({ text: `The ${guestWord(m[1])} ${m[3]} (${m[2]}) is lost with ${node}; its settings are saved first.`, target: mod ? moduleTarget(mod, `the module ${mod}`) : undefined, hint: mod ? "restore it from its backup on another node afterwards" : undefined });
    } else if ((m = l.match(/^replication job (\S+) \S+?(?: \(module (\S+)\))? — removed with the node/))) {
      losses.push({ text: `${m[2] ? `The module ${m[2]}'s` : "A guest's"} replication to or from ${node} is removed; the next site update sets it up again.` });
    } else if ((m = l.match(/^HA rule (\S+) names it .* — kept/))) {
      const mod = m[1].replace(/^ha-/, "");
      losses.push({ text: `The module ${mod} keeps ${node} among its nodes, for a replacement under the same name.`, target: moduleTarget(mod, `the module ${mod}`) });
    } else if (/^the site's PBS ran here/.test(l)) {
      losses.push({ text: `The site's backup server ran on ${node}: its backups are gone with it unless a copy exists elsewhere.`, target: BACKUP_TARGET });
    } else if ((m = l.match(/^park switch port (\S+) on (.+) \(it was /))) {
      ports.push({ sw: m[2], port: m[1] });
    } else if ((m = l.match(/^then: its node record '.*' is (deleted|archived)/))) {
      record = m[1] as "deleted" | "archived";
    } else if ((m = l.match(/^then: asset (\S+) is released from \S+ and kept: it (?:stays placed in (.+)|goes back to stock)/))) {
      asset = { key: m[1], fate: "kept", where: m[2] ?? null };
    } else if ((m = l.match(/^then: asset (\S+) is released from \S+ and removed/))) {
      asset = { key: m[1], fate: "removed", where: null };
    }
  }
  const exit = done?.exit ?? null;
  const state: CheckOutcome["state"] = !done ? "running" : exit === 0 && blockers.length === 0 ? "ok" : blockers.length ? "blocked" : "failed";
  return { state, blockers, losses, ports, asset, record, tail: state === "failed" ? tail(lines) : [] };
}

export interface RemovalOutcome {
  removed: boolean; // out of the cluster
  parked: SwitchPort[];
  notParked: SwitchPort[];
  record: "deleted" | "archived" | null;
  asset: { key: string; fate: "kept" | "removed"; where: string | null } | null;
  assetTrouble: string | null; // the asset step that did not go through
  warnings: string[];
  tail: string[];
}

// The removal's output (its apply phase): what was done.
export function parseRemoval(output: string): RemovalOutcome {
  const lines = outputLines(output);
  const out: RemovalOutcome = { removed: false, parked: [], notParked: [], record: null, asset: null, assetTrouble: null, warnings: [], tail: tail(lines) };
  for (const l of lines) {
    let m: RegExpMatchArray | null;
    if (/^✓ \S+ is out of the cluster\.?$/.test(l)) out.removed = true;
    else if ((m = l.match(/^✓ (.+) port (\S+) parked$/))) out.parked.push({ sw: m[1], port: m[2] });
    else if ((m = l.match(/^could not park (.+) port (\S+) —/))) out.notParked.push({ sw: m[1], port: m[2] });
    else if ((m = l.match(/^✓ its node record is (deleted|archived)/))) out.record = m[1] as "deleted" | "archived";
    else if ((m = l.match(/^✓ asset (\S+) released from \S+ and kept: it (?:stays placed in (.+)|goes back to stock)/))) out.asset = { key: m[1], fate: "kept", where: m[2] ?? null };
    else if ((m = l.match(/^✓ asset (\S+) removed: /))) out.asset = { key: m[1], fate: "removed", where: null };
    else if ((m = l.match(/^asset (\S+) (still plays \S+|is not removed): /))) out.assetTrouble = `The machine's record ${m[1]} ${m[2].startsWith("still") ? "still names the node" : "is only partly removed"}: finish it on its asset page.`;
    else if (/^(could not|the node record '.*' is still registered|CPU inventory not refreshed)/.test(l)) out.warnings.push(l);
  }
  return out;
}
