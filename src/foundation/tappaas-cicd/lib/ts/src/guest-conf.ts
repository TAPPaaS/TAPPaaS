// guest-conf.ts — a guest's /etc/pve config as the CMDB's vm/lxc fields, the
// one parse for every reporter of them. site-manager observes every guest's
// config each sweep; module-manager reports the fields its update or modify
// applied to the guest. Both read them through this file, so the value a verb
// reports is the value the next observation finds.

type Obj = Record<string, unknown>;

export interface GuestNic {
  name: string;
  model?: string;
  mac?: string;
  bridge?: string;
  tag?: number;
}

export interface GuestConf {
  cores?: number;
  memory?: number; // MiB
  template?: boolean;
  unprivileged?: boolean;
  rootfs?: string;
  disks?: { storage: string; size: string }[];
  nics?: GuestNic[];
  mountpoints?: { storage: string; size: string }[];
}

const num = (v: unknown): number | undefined => (typeof v === "number" ? v : typeof v === "string" && /^\d+$/.test(v) ? Number(v) : undefined);

const DISK_KEY = /^(scsi|virtio|sata|ide|efidisk|tpmstate)\d+$/;

/** A guest's /etc/pve config: its own section only (snapshots follow `[…]`). */
export function parseGuestConf(text: string): GuestConf {
  const g: GuestConf = {};
  const disks: { storage: string; size: string }[] = [];
  const nics: GuestNic[] = [];
  const mountpoints: { storage: string; size: string }[] = [];
  for (const line of text.split("\n")) {
    if (line.startsWith("[")) break;
    const m = /^([a-z0-9_-]+):\s*(.*)$/.exec(line.trim());
    if (!m) continue;
    const [, k, v] = m;
    if (k === "cores") g.cores = num(v);
    else if (k === "memory") g.memory = num(v);
    else if (k === "template") g.template = v.trim() === "1";
    else if (k === "unprivileged") g.unprivileged = v.trim() === "1";
    else if (k === "rootfs") g.rootfs = v.split(",")[0];
    else if (/^net\d+$/.test(k)) nics.push(parseGuestNic(k, v));
    else if (/^mp\d+$/.test(k) && v.includes(":")) mountpoints.push({ storage: v.split(":")[0], size: /(?:^|,)size=([^,]+)/.exec(v)?.[1] ?? "" });
    else if (DISK_KEY.test(k) && !/media=cdrom/.test(v) && v.includes(":")) {
      const size = /(?:^|,)size=([^,]+)/.exec(v)?.[1];
      disks.push({ storage: v.split(":")[0], size: size ?? "" });
    }
  }
  if (disks.length) g.disks = disks;
  if (nics.length) g.nics = nics;
  if (mountpoints.length) g.mountpoints = mountpoints;
  return g;
}

// `net0: virtio=BC:24:…,bridge=lan,tag=200` (qemu), `name=eth0,hwaddr=…,bridge=lan` (lxc).
function parseGuestNic(key: string, v: string): GuestNic {
  const kv = new Map(v.split(",").map((p) => p.split("=", 2) as [string, string]));
  const model = [...kv.keys()].find((k) => /^(virtio|e1000e?|rtl8139|vmxnet3)$/.test(k));
  const nic: Obj = {
    name: kv.get("name") ?? key,
    model,
    mac: (kv.get("hwaddr") ?? (model ? kv.get(model) : undefined))?.toLowerCase(),
    bridge: kv.get("bridge"),
    tag: kv.has("tag") ? Number(kv.get("tag")) : undefined,
  };
  for (const k of Object.keys(nic)) if (nic[k] === undefined) delete nic[k];
  return nic as unknown as GuestNic;
}

/** The vm/lxc fields a guest's config sets, as site-manager observes them:
 *  cores and memory; a vm's disks; an lxc's rootfs, unprivileged and its
 *  mount points (as disks); the nics. Fields the config leaves out are left
 *  out. */
export function guestConfAttributes(cls: "vm" | "lxc", c: GuestConf): Obj {
  const a: Obj = { cores: c.cores, memory: c.memory };
  if (cls === "vm") a.disks = c.disks;
  else {
    a.rootfs = c.rootfs;
    a.unprivileged = c.unprivileged;
    a.disks = c.mountpoints;
  }
  a.nics = c.nics;
  for (const k of Object.keys(a)) if (a[k] === undefined) delete a[k];
  return a;
}

/** The shell that prints the configs of the given guests from pmxcfs (any
 *  member holds every node's), each after an `@@conf <path>` line. */
export function guestConfProbe(vmids: number[]): string {
  const ids = vmids.filter((v) => Number.isInteger(v) && v > 0);
  const globs = ids.flatMap((v) => [`/etc/pve/nodes/*/qemu-server/${v}.conf`, `/etc/pve/nodes/*/lxc/${v}.conf`]);
  return `for f in ${globs.join(" ")}; do [ -e "$f" ] && echo "@@conf $f" && cat "$f"; done; true`;
}

/** The probe's output → each guest's config text, by vmid. */
export function parseGuestConfProbe(stdout: string): Map<number, string> {
  const out = new Map<number, string>();
  let vmid: number | null = null;
  let body: string[] = [];
  const flush = (): void => {
    if (vmid !== null) out.set(vmid, body.join("\n"));
  };
  for (const line of stdout.split("\n")) {
    const m = /^@@conf \S*\/(\d+)\.conf$/.exec(line);
    if (m) {
      flush();
      vmid = Number(m[1]);
      body = [];
    } else if (vmid !== null) body.push(line);
  }
  flush();
  return out;
}
