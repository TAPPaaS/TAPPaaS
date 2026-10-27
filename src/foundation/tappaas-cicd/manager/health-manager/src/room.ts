// room.ts — which modules to pause so the update has room (#891).
//
// The update needs memory for a while at two moments: to start a suspended
// module and patch it (#890), and to move a node's HA guests onto the others
// before the node reboots. On a tight cluster neither fits, and the only room
// that can be made for a while — without moving anything for good — is to
// suspend modules their owner allowed to be paused (`pauseOk`) until the update
// is done. This answers both questions with the same rule: does it fit now
// (under the threshold, counted as the update-capacity gate counts), and if
// not, which pauseOk modules — lowest `pausePriority` first, equal ones largest
// first — would make it fit. The update decides whether it may pause at all
// (the maintenance window) and does the pausing; this only counts.
//
// Never a candidate: a foundation module, a machine, the module the room is
// for, a guest that is not running, and — for a drain — a guest on the node
// being rebooted that is not HA (it restarts with the node, so it needs no room).

import { join } from "path";
import { isManaged, loadConfigModules, readModuleJson } from "./config";
import { configField } from "./checks";
import { countedMem } from "./memcount";
import { ClusterClient, ConfigModule, GuestMemory, NodeCapacity } from "./types";

export type RoomTarget = { kind: "resume"; module: string } | { kind: "drain"; node: string };

export interface RoomResult {
  target: string; // "resume <module>" | "drain <node>"
  fits: boolean; // fits as the cluster is now
  possible: boolean; // fits once `pause` is suspended (true when fits)
  pause: string[]; // the modules to suspend, in order; empty when it fits
  detail: string;
}

const GIB = 1024 ** 3;
const gib = (b: number): string => (b / GIB).toFixed(1);

interface Candidate {
  module: string;
  guest: GuestMemory;
  priority: number;
  mem: number;
}

function candidates(caps: NodeCapacity[], modules: ConfigModule[], exclude: string): Candidate[] {
  const byVmid = new Map(modules.map((m) => [m.vmid, m]));
  const out: Candidate[] = [];
  for (const g of caps.flatMap((c) => c.guests)) {
    if (g.status !== "running") continue;
    const m = byVmid.get(g.vmid);
    if (!m || !m.pauseOk || m.module === exclude || m.suspended) continue;
    if (m.stack === "foundation") continue; // the site runs on them: never paused
    out.push({ module: m.module, guest: g, priority: m.pausePriority ?? 50, mem: countedMem(g) });
  }
  return out;
}

const order = (a: Candidate, b: Candidate): number => a.priority - b.priority || b.mem - a.mem || a.module.localeCompare(b.module);

export function checkRoom(
  client: ClusterClient,
  configDir: string,
  defaultNode: string,
  threshold: number,
  target: RoomTarget,
): RoomResult {
  const caps = client.nodeCapacity();
  const modules = loadConfigModules(configDir, defaultNode).filter(isManaged);
  const limit = (c: NodeCapacity): number => (threshold / 100) * c.physicalMem;

  if (target.kind === "resume") {
    const name = `resume ${target.module}`;
    const m = modules.find((x) => x.module === target.module);
    const g = m ? caps.flatMap((c) => c.guests).find((x) => x.vmid === m.vmid) : undefined;
    if (!m || !g) return { target: name, fits: false, possible: false, pause: [], detail: `${target.module} has no guest on the cluster` };
    if (g.status === "running") return { target: name, fits: true, possible: true, pause: [], detail: `${target.module} is running already` };
    const node = caps.find((c) => c.node === g.node)!;
    const raw = readModuleJson(join(configDir, `${m.module}.json`)) ?? {};
    const cfgMem = Number(configField(raw, "memory"));
    const need = countedMem(g, Number.isFinite(cfgMem) && cfgMem > 0 ? Math.max(g.declaredMem, cfgMem * 1024 ** 2) : g.declaredMem);
    let committed = node.committedMem;
    const fits = committed + need < limit(node);
    const pause: string[] = [];
    if (!fits) {
      for (const c of candidates(caps, modules, m.module).filter((x) => x.guest.node === node.node).sort(order)) {
        if (committed + need < limit(node)) break;
        committed -= c.mem;
        pause.push(c.module);
      }
    }
    const possible = committed + need < limit(node);
    return {
      target: name,
      fits,
      possible,
      pause: fits ? [] : possible ? pause : [],
      detail: fits
        ? `${m.module} ${gib(need)}G fits on ${node.node} (${gib(node.committedMem + need)}/${gib(node.physicalMem)}G)`
        : possible
          ? `${m.module} ${gib(need)}G fits on ${node.node} once ${pause.join(", ")} ${pause.length === 1 ? "is" : "are"} paused`
          : `${m.module} ${gib(need)}G does not fit on ${node.node}, even with every pauseOk module there paused`,
    };
  }

  // drain: the node's running HA guests move to the others for its reboot. The
  // others' room is counted together — the CRM spreads them — so this is the
  // test that the moving load fits at all, not a placement.
  const name = `drain ${target.node}`;
  const node = caps.find((c) => c.node === target.node);
  const others = caps.filter((c) => c.node !== target.node);
  if (!node) return { target: name, fits: false, possible: false, pause: [], detail: `${target.node} is not a node of the cluster` };
  if (others.length === 0) return { target: name, fits: true, possible: true, pause: [], detail: "a single node: nothing moves" };
  let moving = node.guests.filter((g) => g.status === "running" && g.ha).reduce((a, g) => a + countedMem(g), 0);
  let committed = others.reduce((a, c) => a + c.committedMem, 0);
  const room = others.reduce((a, c) => a + limit(c), 0);
  const fits = committed + moving < room;
  const pause: string[] = [];
  if (!fits) {
    // Pausing an HA guest on the node takes it out of the move; pausing one on
    // another node frees room there. A non-HA guest on the node does neither.
    const cands = candidates(caps, modules, "").filter((c) => c.guest.node !== target.node || c.guest.ha).sort(order);
    for (const c of cands) {
      if (committed + moving < room) break;
      if (c.guest.node === target.node) moving -= c.mem;
      else committed -= c.mem;
      pause.push(c.module);
    }
  }
  const possible = committed + moving < room;
  return {
    target: name,
    fits,
    possible,
    pause: fits ? [] : possible ? pause : [],
    detail: fits
      ? `${target.node}'s HA guests (${gib(moving)}G) fit on the other nodes`
      : possible
        ? `${target.node}'s HA guests fit on the other nodes once ${pause.join(", ")} ${pause.length === 1 ? "is" : "are"} paused`
        : `${target.node}'s HA guests do not fit on the other nodes, even with every pauseOk module paused`,
  };
}
