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
  return grafanaLoki(ctx, `{host="${host}"}`);
}

// Grafana Explore on a LogQL query: a rule's prepared one (the query its alert
// mail links), over the range given.
export function grafanaLoki(ctx: JumpContext, expr: string, range: { from: string; to: string } = { from: "now-6h", to: "now" }): string | null {
  const g = publicName(ctx, "logging");
  if (!g || !installed(ctx, "logging")) return null;
  const panes = {
    a: {
      datasource: "loki",
      queries: [{ refId: "A", expr, datasource: { type: "loki", uid: "loki" } }],
      range,
    },
  };
  return `https://${g}/explore?schemaVersion=1&orgId=1&panes=${enc(JSON.stringify(panes))}`;
}

// The logs of a CMDB object (the Health panel's Logs link): the host its lines
// carry (a guest's or a node's own name, a module's VM), and for each condition
// whose source names a query (a threat's rule) that query, from an hour before
// its first hit to now.
export interface ObjectLogs { host: string | null; url: string | null; rules: { type: string; alert: string; url: string }[] }
export function objectLogs(ctx: JumpContext, o: { class: string; name: string; module: string | null }, conds: { type: string; hits?: { first: string; alerts?: string[]; query?: string } }[]): ObjectLogs {
  const m = o.module ? ctx.modules.find((x) => x.name === o.module) : undefined;
  const host = ["vm", "lxc", "machine", "device"].includes(o.class) ? o.name : m ? m.vmname ?? m.name : null;
  const rules: ObjectLogs["rules"] = [];
  for (const c of conds) {
    if (!c.hits?.query) continue;
    const from = Date.parse(c.hits.first);
    const url = grafanaLoki(ctx, c.hits.query, { from: Number.isNaN(from) ? "now-24h" : String(from - 3600_000), to: "now" });
    if (url) rules.push({ type: c.type, alert: (c.hits.alerts ?? []).join(", "), url });
  }
  return { host, url: host ? grafanaExplore(ctx, host) : null, rules };
}

// The shipped dashboard of a CI's class (logging's dashboards.nix), at that CI:
// var-ci, or for a pool its node and name.
const DASHBOARD: Record<string, string> = { machine: "tappaas-node", vm: "tappaas-guest", lxc: "tappaas-guest", "storage-pool": "tappaas-pool", datastore: "tappaas-datastore", "proxy-route": "tappaas-service" };
export function grafanaDashboard(ctx: JumpContext, cls: string, labels: Record<string, string>): string | null {
  const g = publicName(ctx, "logging");
  const uid = DASHBOARD[cls];
  if (!g || !uid) return null;
  const vars = cls === "storage-pool" ? `var-node=${enc(labels.tappaas_ci_id ?? "")}&var-pool=${enc(labels.pool ?? "")}` : `var-ci=${enc(labels.tappaas_ci_id ?? "")}`;
  return `https://${g}/d/${uid}/?orgId=1&${vars}`;
}

// The CI's traces (ADR-046 D7, P6): Grafana's Explore on the Tempo data source,
// a TraceQL search by the CI's id, the last hour. Null where Grafana is not
// published, as for the dashboards.
export function grafanaTraces(ctx: JumpContext, ciId: string): string | null {
  const g = publicName(ctx, "logging");
  if (!g || !/^[0-9a-f-]{36}$/.test(ciId)) return null;
  const panes = {
    t: {
      datasource: "tempo",
      queries: [{ refId: "A", datasource: { type: "tempo", uid: "tempo" }, queryType: "traceql", query: `{ resource.tappaas.ci.id = "${ciId}" }` }],
      range: { from: "now-1h", to: "now" },
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
