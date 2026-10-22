// jumps.ts — "Open in …" (ADR-034 D2, spike §5.6): for an object in view, the
// component UIs that show it, at that object, in a new tab. For debugging only;
// the console never embeds or re-implements them. Built from the topology, the
// module list and the environments; a target that is not installed offers no
// jump. The status route offers none (its zones reach none of the targets).

import { EnvironmentRow, ModuleRow, TopologyDoc } from "./model";

export interface Jump {
  target: "proxmox" | "opnsense" | "grafana" | "pbs" | "authentik" | "unifi";
  label: string;
  url: string;
}

export interface JumpContext {
  topology: TopologyDoc | null;
  modules: ModuleRow[];
  environments: EnvironmentRow[];
  mgmtDomain: string; // mgmt.internal
  pbsStore: string; // the PBS datastore the site backs up to
}

export type JumpKind = "node" | "module" | "switch" | "port" | "lag" | "ap" | "zone" | "peer" | "site" | "disk" | "pool";

const enc = encodeURIComponent;

// A module's public name as network:proxy derives it: <vmname>.<its environment's domain>.
function publicName(ctx: JumpContext, module: string): string | null {
  const m = ctx.modules.find((x) => x.name === module);
  if (!m) return null;
  const env = ctx.environments.find((e) => e.name === m.environment);
  const domain = env?.domains?.primary;
  return domain ? `${m.vmname ?? m.name}.${domain}` : null;
}

export function proxmoxUrl(ctx: JumpContext, node: string, guest?: { vmid: number; kind: string }): string {
  const what = guest ? `${guest.kind === "lxc" ? "lxc" : "qemu"}/${guest.vmid}` : `node/${node}`;
  return `https://${node}.${ctx.mgmtDomain}:8006/#v1:0:=${what}`;
}

// A node's own panel in Proxmox, at one tab: its state hash is view, the
// selected object, the log tab (4: tasks), then the node's tab (2: Disks,
// "=zfs": Disks › ZFS).
export function proxmoxNodeTab(ctx: JumpContext, node: string, tab: "disks" | "zfs"): string {
  return `${proxmoxUrl(ctx, node)}:4:${tab === "disks" ? "2" : "=zfs"}`;
}

// Grafana Explore on the logs of one host (the logging module's Loki, uid "loki").
export function grafanaExplore(ctx: JumpContext, host: string): string | null {
  const g = publicName(ctx, "logging");
  if (!g) return null;
  const panes = {
    a: {
      datasource: "loki",
      queries: [{ refId: "A", expr: `{host="${host}"}`, datasource: { type: "loki", uid: "loki" } }],
      range: { from: "now-6h", to: "now" },
    },
  };
  return `https://${g}/explore?schemaVersion=1&orgId=1&panes=${enc(JSON.stringify(panes))}`;
}

function opnsense(ctx: JumpContext, path = "/"): string {
  return `https://firewall.${ctx.mgmtDomain}:8443${path}`;
}

function installed(ctx: JumpContext, module: string): boolean {
  return ctx.modules.some((m) => m.name === module);
}

function where(ctx: JumpContext, module: string): { node: string; vmid: number; kind: string } | null {
  for (const n of ctx.topology?.nodes ?? []) {
    const g = n.guests.find((x) => x.module === module);
    if (g && g.vmid !== null) return { node: n.name, vmid: g.vmid, kind: g.kind };
  }
  const m = ctx.modules.find((x) => x.name === module);
  const node = m?.actualNode ?? m?.node;
  return m && node && m.vmid !== null ? { node, vmid: m.vmid, kind: m.kind } : null;
}

export function jumpsFor(kind: JumpKind, id: string, ctx: JumpContext, sw?: string): Jump[] {
  const out: Jump[] = [];
  const push = (target: Jump["target"], label: string, url: string | null): void => {
    if (url) out.push({ target, label, url });
  };
  const unifi = (switchName?: string): void => {
    const all = ctx.topology?.switches ?? [];
    const s = all.find((x) => x.name === switchName && x.controllerAddress) ?? all.find((x) => x.controllerAddress);
    // The controller's device list: a port is not deep-linkable in UniFi today.
    if (s?.controllerAddress) push("unifi", "UniFi devices", `${s.controllerAddress.replace(/\/$/, "")}/network/default/devices`);
  };
  switch (kind) {
    case "node":
      push("proxmox", `Proxmox · ${id}`, proxmoxUrl(ctx, id));
      if (installed(ctx, "logging")) push("grafana", "Grafana · logs", grafanaExplore(ctx, id));
      break;
    case "module": {
      const w = where(ctx, id);
      if (w) push("proxmox", `Proxmox · ${w.kind === "lxc" ? "CT" : "VM"} ${w.vmid}`, proxmoxUrl(ctx, w.node, w));
      const m = ctx.modules.find((x) => x.name === id);
      if (installed(ctx, "logging") && m) push("grafana", "Grafana · logs", grafanaExplore(ctx, m.vmname ?? m.name));
      if (installed(ctx, "backup") && m && m.vmid !== null) push("pbs", "PBS · backups", `https://backup.${ctx.mgmtDomain}:8007/#DataStore-${ctx.pbsStore}`);
      if (id === "network") push("opnsense", "OPNsense", opnsense(ctx));
      if (id === "identity") {
        const a = publicName(ctx, "identity");
        if (a) push("authentik", "Authentik admin", `https://${a}/if/admin/`);
      }
      if (id === "unifi-os") unifi();
      if (id === "backup") push("pbs", "PBS", `https://backup.${ctx.mgmtDomain}:8007/`);
      break;
    }
    case "switch":
    case "port":
    case "lag":
      unifi(kind === "switch" ? id : sw);
      break;
    case "ap":
      unifi();
      break;
    case "zone":
      push("opnsense", "OPNsense · interfaces", opnsense(ctx, "/ui/interfaces/overview"));
      push("opnsense", "OPNsense · firewall rules", opnsense(ctx, "/firewall_rules.php"));
      break;
    case "site":
      push("opnsense", "OPNsense", opnsense(ctx));
      for (const n of ctx.topology?.nodes ?? []) push("proxmox", `Proxmox · ${n.name}`, proxmoxUrl(ctx, n.name));
      if (installed(ctx, "logging")) {
        const g = publicName(ctx, "logging");
        if (g) push("grafana", "Grafana", `https://${g}/`);
      }
      break;
    // A disk or a pool: id is its node.
    case "disk":
      push("proxmox", `Proxmox · ${id} disks`, proxmoxNodeTab(ctx, id, "disks"));
      break;
    case "pool":
      push("proxmox", `Proxmox · ${id} ZFS`, proxmoxNodeTab(ctx, id, "zfs"));
      push("proxmox", `Proxmox · ${id} disks`, proxmoxNodeTab(ctx, id, "disks"));
      break;
    case "peer":
      if (installed(ctx, "backup")) push("pbs", "PBS · remotes", `https://backup.${ctx.mgmtDomain}:8007/#pbsRemoteView`);
      break;
  }
  return out;
}
