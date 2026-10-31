// deviceops.tsx — the changes a device offers, on the page that shows it in
// full (the asset's page under Assets): a switch port's record and its
// programming (switch-manager update-port, then reconcile) or parking; a
// node's uplinks (site-manager node network show / set); a recorded device's
// record changed or removed; a wire attached to a patch panel or taken off it;
// and the asset's lifecycle as asset-manager's verbs — allocate to a role,
// release, receive, fault and repaired, dispose — and a port's record. Each is
// a Step (operate.tsx): Change → Preview (--check) → Apply.

import { RackCable, Topology } from "../types";
import { OperateButton, Step } from "../operate";
import { freePanelPorts } from "./devicegraph";

// A switch port's change (mockup 3): its record first, then the switch.
export function PortChange({ t, sw, port, type, parked, lag, mode, zone, description }: { t: Topology; sw: string; port: string; type: string | null; parked: boolean; lag: string | null; mode: string; zone: string; description: string | null }) {
  const zones = t.zones.filter((z) => z.vlan !== null && z.state !== "Disabled").map((z) => z.name);
  const steps: Step[] = [
    {
      title: `1 · The port's record: switch-manager update-port '${sw}' ${port}`,
      bin: "switch-manager",
      verb: "update-port",
      fixed: [sw, port],
      // The port as it is; a zone only for an access port (a trunk's first VLAN is not "its" zone).
      initial: { "--type": type ?? "device", "--mode": mode === "access" ? "access" : mode || "access", "--zone": mode === "access" ? zone : "", "--description": description ?? "" },
      choices: { "--zone": zones },
      note: "This writes the port's record (switch-configuration-actual.json) and nothing else: the switch is programmed in the next step. An access port carries one zone; a trunk the zones in --tagged.",
    },
    {
      title: "2 · Program the switch: switch-manager reconcile",
      bin: "switch-manager",
      verb: "reconcile",
      note: "The preview is the delta per port (interrogate, update-desired, delta — nothing applied). Apply programs every pending change on every switch, not only this port's: read the preview's list before you apply.",
    },
  ];
  // A port is given back by parking it (#853): remove-port sets it on the switch
  // as an access port in iotLocal, at once, then records it parked. The
  // controller's own default profile is never restored: it is a trunk of every
  // network, the exposure parking removes.
  const park: Step[] = [
    {
      title: `Park port ${port}: switch-manager remove-port '${sw}' ${port}`,
      bin: "switch-manager",
      verb: "remove-port",
      fixed: [sw, port],
      note: "Sets the port on the switch now, alone, as an access port in iotLocal (tier 6, no internet, nothing else reachable), then replaces its record with a parked one. Whatever is plugged in loses what the port carried. Only this port is pushed, nothing else pending on the switch.",
    },
    { title: "Read the switch again: switch-manager reconcile (preview)", bin: "switch-manager", verb: "reconcile", note: "Its preview interrogates the switch: the port shows parked and in sync. Nothing needs applying for it." },
  ];
  return (
    <>
      <OperateButton label={`Change port ${port}…`} title={`Port ${port} · ${sw}`} steps={steps} />
      {!parked && !lag ? <OperateButton label="Park…" kind="danger" title={`Port ${port} · ${sw}: park`} steps={park} /> : null}
    </>
  );
}

// A node's uplinks: read them, or set them (preview without --apply).
export function NodeNetwork({ node }: { node: string }) {
  return (
    <>
      <OperateButton label="Network: show" title={`${node} — uplinks`} steps={[{ title: `site-manager node network show ${node}`, bin: "site-manager", verb: "node network show", fixed: [node] }]} />
      <OperateButton
        label="Network: set…"
        title={`${node} — set the uplinks`}
        steps={[
          {
            title: `site-manager node network set ${node}`,
            bin: "site-manager",
            verb: "node network set",
            fixed: [node],
            note: "The preview (without --apply) declares the uplink in config/<node>.json and previews the change on the node: the declaration is written, the node is not touched. Apply drains the node (HA maintenance), moves lan onto the declared ports under a 45 s rollback, confirms and brings the node back. --yes answers the manager's own prompt for the node's name.",
          },
        ]}
      />
    </>
  );
}

// A recorded device's own record: change it, or remove it once nothing names it.
export function DeviceRecordActions({ name, cabled, placed }: { name: string; cabled: boolean; placed: boolean }) {
  const rm = (verb: string, title: string, extra: Partial<Step> = {}): Step => ({ title, bin: "asset-manager", verb, fixed: [name], ...extra });
  return (
    <>
      <OperateButton label="Change the record…" title={`The record of ${name}`} steps={[rm("asset modify", `asset-manager asset modify '${name}'`, { note: "Its kind, vendor, model, serial, tag, ports (a count or a list), display name, description or procurement; --check previews." })]} />
      {!placed && !cabled ? <OperateButton label="Remove the record…" kind="danger" title={`Remove ${name}`} steps={[rm("asset remove", `asset-manager asset remove '${name}'`)]} /> : null}
    </>
  );
}

// A wire through a patch panel: asset-manager cable split, its --check the preview.
export function PanelSplit({ t, c, many }: { t: Topology; c: RackCable; many: boolean }) {
  const free = freePanelPorts(t);
  if (!free.length) return null;
  const end = `${c.from.device}:${c.from.port}`;
  return (
    <OperateButton
      label={many ? `Attach ${c.from.port} ↔ ${c.to.port} to a patch panel…` : "Attach to patch panel…"}
      title={`${end} — ${c.to.device}:${c.to.port} through a patch panel`}
      steps={[{ title: `asset-manager cable split '${end}' --via <panel:port>`, bin: "asset-manager", verb: "cable split", fixed: [end], only: ["--via"], choices: { "--via": free }, note: "The link becomes two recorded wires: this port to the panel port's front, its rear to the far end. The Device view keeps one link; the racks draw the two wires. Preview: asset-manager's --check." }]}
    />
  );
}

// Undo it: asset-manager cable join at the panel port.
export function PanelJoin({ c }: { c: RackCable }) {
  const v = c.via?.[0];
  if (!v) return null;
  return (
    <OperateButton
      label="Remove patch panel"
      title={`${c.from.device}:${c.from.port} — ${c.to.device}:${c.to.port} without ${v.device}`}
      steps={[{ title: `asset-manager cable join '${v.device}:${v.port}'`, bin: "asset-manager", verb: "cable join", fixed: [`${v.device}:${v.port}`], note: "The two wires through the panel port are one link again: the topology's own, or one recorded cable when it was recorded. Preview: asset-manager's --check." }]}
    />
  );
}

// Attach a wire here…: a link, chosen by the end it starts from, split through this panel port.
export function PanelAttach({ panelPort, links }: { panelPort: string; links: { end: string; text: string }[] }) {
  return (
    <OperateButton
      label="Attach a wire here…"
      title={`A link through ${panelPort}`}
      steps={[
        {
          title: `asset-manager cable split <device:port> --via '${panelPort}'`,
          bin: "asset-manager",
          verb: "cable split",
          only: [],
          initial: { "--via": panelPort },
          choices: { "@device:port": links.map((l) => l.end) },
          note: <>The link on the port you choose becomes two recorded wires: that port to {panelPort}'s front, its rear to the far end. The links: {links.map((l) => l.text).join("; ")}. Preview: asset-manager's --check.</>,
        },
      ]}
    />
  );
}

// ── the asset's lifecycle (asset-manager asset …) ──────────────────────

const RM = "asset-manager";
const am = (asset: string, verb: string, title: string, extra: Partial<Step> = {}): Step => ({ title, bin: RM, verb, fixed: [asset], ...extra });

// The roles an asset can take: the topology's devices of its kind that no
// other asset plays.
export function rolesFor(t: Topology | null, kind: string, played: Set<string>): string[] {
  if (!t) return [];
  const names =
    kind === "server" ? [...t.nodes.map((n) => n.name), ...(t.devices ?? []).filter((d) => d.kind === "machine").map((d) => d.name)]
    : kind === "switch" ? t.switches.map((s) => s.name)
    : kind === "access-point" ? t.accessPoints.map((a) => a.name)
    : (t.devices ?? []).filter((d) => d.kind === "device").map((d) => d.name);
  return [...new Set(names)].filter((n) => !played.has(n)).sort((a, b) => a.localeCompare(b, "en", { numeric: true }));
}

export function allocateSteps(asset: string, roles: string[]): Step[] {
  return [
    am(asset, "asset allocate", `asset-manager asset allocate '${asset}' --role <name>`, {
      only: ["--role"],
      suggest: { "--role": roles },
      note: "The asset plays the role from now on: the topology's node or machine (a server), switch, access point or device of that name is this asset. Its placement and recorded cables follow it under the role's name. One asset plays a role; --check previews.",
    }),
  ];
}

export function releaseSteps(asset: string, role: string): Step[] {
  return [am(asset, "asset release", `asset-manager asset release '${asset}'`, { note: `It no longer plays ${role}: the role stays the topology's, played by no asset until another is allocated to it. Its placement and recorded cables stay with the asset, under its own name.` })];
}

export function receiveSteps(asset: string): Step[] {
  return [am(asset, "asset receive", `asset-manager asset receive '${asset}'`, { note: "Ordered → in stock: it has arrived. Place it, or allocate it to a role, afterwards." })];
}

export function faultSteps(asset: string): Step[] {
  return [am(asset, "asset fault", `asset-manager asset fault '${asset}' --note <text>`, { only: ["--note"], note: "A flag beside its stage, with what is wrong: it stays where it is and keeps its role until you release it." })];
}

export function repairedSteps(asset: string): Step[] {
  return [am(asset, "asset repaired", `asset-manager asset repaired '${asset}'`, { note: "Clears the faulty flag and its note." })];
}

export function disposeSteps(asset: string): Step[] {
  return [
    am(asset, "asset dispose", `asset-manager asset dispose '${asset}' --how <how>`, {
      choices: { "--how": ["sold", "recycled", "returned", "lost"] },
      note: "Its last stage: sold, recycled, returned or lost, when (default today), and whether its disks were wiped. The check refuses an asset still in a role, placed, or with a recorded cable; its record stays.",
    }),
  ];
}

export function portModifySteps(asset: string, port: string): Step[] {
  return [am(asset, "port modify", `asset-manager port modify '${asset}' ${port}`, { fixed: [asset, port], note: "The port's record: its kind, speed, MAC, role (lan, wan, bmc), module or side, as --set field=value or --unset field." })];
}

// The lifecycle buttons for an asset in its stage.
export function AssetLifecycle({ t, a, played }: { t: Topology | null; a: { name: string; kind: string; stage: string; role: string | null; faulty?: boolean; placed: boolean }; played: Set<string> }) {
  const roles = rolesFor(t, a.kind, played);
  return (
    <>
      {a.stage === "ordered" ? <OperateButton label="Receive…" kind="primary" title={`Receive ${a.name}`} steps={() => receiveSteps(a.name)} /> : null}
      {a.stage !== "ordered" && a.stage !== "disposed" && !a.role ? <OperateButton label="Allocate…" title={`Allocate ${a.name} to a role`} steps={() => allocateSteps(a.name, roles)} hint={roles.length ? undefined : "no role of its kind is free in the topology: type one"} /> : null}
      {a.role ? <OperateButton label="Release…" kind="danger" title={`Release ${a.name} from ${a.role}`} steps={() => releaseSteps(a.name, a.role!)} /> : null}
      {a.stage !== "disposed" ? a.faulty ? <OperateButton label="Repaired…" title={`${a.name} is repaired`} steps={() => repairedSteps(a.name)} /> : <OperateButton label="Faulty…" title={`Mark ${a.name} faulty`} steps={() => faultSteps(a.name)} /> : null}
      {a.stage !== "disposed" && !a.role && !a.placed ? <OperateButton label="Dispose…" kind="danger" title={`Dispose of ${a.name}`} steps={() => disposeSteps(a.name)} /> : null}
    </>
  );
}
