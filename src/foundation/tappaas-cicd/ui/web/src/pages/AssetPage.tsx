// AssetPage — one asset in full (/assets/<name>, by its own name or the role
// it plays): its record (display name, kind, vendor, model, serial, asset tag,
// stage, the faulty flag, procurement, disposal), the role it plays and since
// when, where it stands, its ports with their MACs and cables, the history of
// its allocations, and its CMDB record — open events, trace, relations,
// history (CiPanel.tsx, embedded). The operations on it are here: its record
// changed or removed, its lifecycle (allocate, release, receive, faulty,
// repaired, dispose; one that holds disks removed or disposed of with them,
// or them to stock first, as its form asks), its placement (place, move, unplace), a node's uplinks,
// a switch's or an access point's location, and per port its record, a switch
// port's zone or parking, a cable recorded or removed, a wire attached to a
// patch panel or taken off it. The disks in it (ADR-042) are listed by bay
// with their serial, size, kind, health and pool, each opening its own page:
// a disk recorded or the ones its CI knows adopted, a disk moved or taken
// out. A disk's own page has its record, the asset it is in, the assets it
// has been in, its CMDB record, and its changes: move, take out, change,
// remove, and dispose with whether it was wiped. The side panels' Details
// link opens it.

import { ReactNode, useEffect, useMemo } from "react";
import { useRead } from "../api";
import { allocatedSince, allocationHistory, findAsset } from "../assetview";
import { assetPath, assetsSelectPath, modulePath, portAnchor } from "../details";
import { OperateButton } from "../operate";
import { panelPortUse, splittable } from "../physical/devicegraph";
import { AssetLifecycle, DeviceRecordActions, NodeNetwork, PanelAttach, PanelJoin, PanelSplit, PortChange, faultSteps, portModifySteps, receiveSteps, repairedSteps } from "../physical/deviceops";
import { BayRow, DiskPlacements, DiskRowOps, diskAddSteps, diskAdoptSteps, diskDisposeSteps, diskModifySteps, diskMoveSteps, diskRemoveSteps, diskUnplaceSteps } from "../physical/disks";
import { DISK_COLOR, DISK_LEVEL, adoptOffer, healthText, hostChoices, poolText } from "../diskview";
import { bytes } from "../physical/storage";
import { PlaceActions, RecordDeviceButton, cableAddSteps, cableRemoveSteps } from "../physical/rackops";
import { viewLink } from "../physical/views";
import { DeviceLocationButton, LocationLink, PlacementLine } from "../locations";
import { AssetRow, AssetTree, CiHistoryRow, CiRecord, ModuleSummary, RackCable, Topology } from "../types";
import { Badge, KV, Link, OpenIn, ReadState, Section, canOperate, useHash, useMe, when } from "../ui";
import { CiPanel } from "./CiPanel";
import { StageBadge } from "./Assets";

// A CMDB attribute's value, or undefined.
const attr = (ci: CiRecord | null, name: string): unknown => ci?.attributes.find((a) => a.name === name)?.value;

function plain(v: unknown): ReactNode {
  if (v === undefined || v === null || v === "") return null;
  if (typeof v === "boolean") return v ? "yes" : "no";
  if (typeof v === "object") {
    return (
      <span className="kv-inline">
        {Object.entries(v as Record<string, unknown>).map(([k, x]) => (
          <span key={k}>
            <span className="muted">{k}</span> {typeof x === "boolean" ? (x ? "yes" : "no") : String(x)}
          </span>
        ))}
      </span>
    );
  }
  return String(v);
}

// What the topology calls the role an asset plays: a node, a switch, an access point.
function roleKind(t: Topology | null, name: string): "node" | "switch" | "ap" | null {
  if (!t) return null;
  if (t.nodes.some((n) => n.name === name)) return "node";
  if (t.switches.some((s) => s.name === name)) return "switch";
  if (t.accessPoints.some((a) => a.name === name)) return "ap";
  return null;
}

// The disks in an asset, by bay: each its own page, its health, its pool.
function DiskTable({ a, tree, operator }: { a: AssetRow; tree: AssetTree | null; operator: boolean }) {
  return (
    <table className="table compact small">
      <thead>
        <tr>
          <th>bay</th>
          <th>disk</th>
          <th>serial</th>
          <th>size</th>
          <th>kind</th>
          <th>health</th>
          <th>pool</th>
          {operator ? <th></th> : null}
        </tr>
      </thead>
      <tbody>
        {a.disks.map((d) => (
          <tr key={d.name}>
            <td className="mono">{d.bay ?? ""}</td>
            <td>
              <Link to={assetPath(d.name)}>{d.displayName ?? d.name}</Link>
              {d.displayName ? <span className="muted mono"> {d.name}</span> : null}
              {d.faulty ? <> <Badge level="warn">faulty</Badge></> : null}
            </td>
            <td className="mono">{d.serial ?? ""}</td>
            <td className="nowrap">{d.size !== null ? bytes(d.size) : ""}</td>
            <td>{d.kind ?? ""}</td>
            <td>
              <i className="st-swatch" style={{ background: DISK_COLOR[d.state] }} /> <span className={d.state === "ok" ? "" : "muted"}>{healthText(d)}</span>
            </td>
            <td>{poolText(d.pool)}</td>
            {operator ? <td><DiskRowOps d={d} hosts={hostChoices(tree, { in: d.host ? { asset: d.host, bay: d.bay } : undefined })} /></td> : null}
          </tr>
        ))}
      </tbody>
    </table>
  );
}

// A disk's own changes, by where it is and its stage.
function DiskOps({ a, tree }: { a: AssetRow; tree: AssetTree | null }) {
  const hosts = hostChoices(tree, a);
  const live = a.stage !== "disposed";
  return (
    <>
      {a.stage === "ordered" ? <OperateButton label="Receive…" kind="primary" title={`Receive ${a.name}`} steps={() => receiveSteps(a.name)} /> : null}
      {live && a.stage !== "ordered" ? <OperateButton label={a.in ? "Move to…" : "Put in…"} title={`${a.in ? "Move" : "Put"} ${a.name}${a.in ? "" : " into an asset"}`} steps={() => diskMoveSteps(a.name, hosts, a.in?.bay ?? null)} /> : null}
      {a.in ? <OperateButton label="Take out…" kind="danger" title={`Take ${a.name} out of ${a.in.asset}`} steps={() => diskUnplaceSteps(a.name, a.in!.asset)} /> : null}
      {live ? <OperateButton label="Change…" title={`The record of ${a.name}`} steps={() => diskModifySteps(a.name)} /> : null}
      {live ? a.faulty ? <OperateButton label="Repaired…" title={`${a.name} is repaired`} steps={() => repairedSteps(a.name)} /> : <OperateButton label="Faulty…" title={`Mark ${a.name} faulty`} steps={() => faultSteps(a.name)} /> : null}
      {live && !a.in ? <OperateButton label="Dispose…" kind="danger" title={`Dispose of ${a.name}`} steps={() => diskDisposeSteps(a.name)} /> : null}
      {live ? <OperateButton label="Remove the record…" kind="danger" title={`Remove ${a.name}`} steps={() => diskRemoveSteps(a.name)} /> : null}
    </>
  );
}

const endsAt = (c: RackCable, device: string, port: string): boolean => [c.from, c.to].some((e) => e.device === device && e.port === port);

// A port's operations: its record, a switch port's change, its cable's.
function PortOps({ a, port, t }: { a: AssetRow; port: AssetRow["ports"][number]; t: Topology | null }) {
  const v = t?.positions ?? null;
  const dev = a.placedAs;
  const sw = t?.switches.find((s) => s.name === dev);
  const sp = sw?.ports.find((p) => p.port === port.name);
  const cables = (v?.cables ?? []).filter((c) => endsAt(c, dev, port.name));
  const recorded = cables.find((c) => c.source === "recorded" && !c.segments?.length);
  const panel = a.kind === "patch-panel" ? panelPortUse(v?.cables ?? [], dev).get(port.name) : undefined;
  const links = a.kind === "patch-panel" && t ? splittable(t) : [];
  return (
    <span className="toolbar">
      {port.listed ? <OperateButton label="Port…" title={`Port ${port.name} of ${a.name}`} steps={() => portModifySteps(a.name, port.name)} /> : null}
      {sw && sp && t ? <PortChange t={t} sw={sw.name} port={sp.port} type={sp.type} parked={sp.parked === true} lag={sp.lag} mode={sp.mode} zone={sp.zones[0] ?? ""} description={sp.description} /> : null}
      {v && t ? cables.map((c, i) => (c.segments?.length ? <PanelJoin key={i} c={c} /> : <PanelSplit key={i} t={t} c={c} many={cables.length > 1} />)) : null}
      {v && recorded ? <OperateButton label="Remove the cable…" kind="danger" title={`The recorded cable on ${dev}:${port.name}`} steps={() => cableRemoveSteps(`${dev}:${port.name}`)} /> : null}
      {v && !cables.length && a.kind !== "patch-panel" ? <OperateButton label="Record a cable…" title={`A cable from ${dev}:${port.name}`} steps={() => cableAddSteps(`${dev}:${port.name}`)} /> : null}
      {a.kind === "patch-panel" && links.length && !panel?.front && !panel?.rear ? <PanelAttach panelPort={`${dev}:${port.name}`} links={links} /> : null}
    </span>
  );
}

export function AssetPage({ name }: { name: string }) {
  const r = useRead<AssetTree>("assets/tree");
  const topo = useRead<Topology>("topology");
  const mods = useRead<ModuleSummary[]>("modules").env?.data ?? null;
  const operator = canOperate(useMe());
  const hash = useHash();
  const tree = r.env?.data ?? null;
  const t = topo.env?.data ?? null;
  const v = t?.positions ?? null;
  const a = findAsset(tree, name);
  // A disk's CI is of the disk class, part of the asset it is in (ADR-042).
  const rec = useRead<CiRecord>(a ? `cmdb/ci?name=${encodeURIComponent(a.name)}&class=${a.kind === "disk" ? "disk" : "asset"}` : null);
  const ci = rec.env?.data ?? null;
  const hist = useRead<CiHistoryRow[]>(ci ? `cmdb/ci/${encodeURIComponent(ci.id)}/history` : null, 60_000);
  const allocations = useMemo(() => allocationHistory(hist.env?.data ?? []), [hist.env]);
  const played = useMemo(() => new Set((tree?.assets ?? []).map((x) => x.role).filter((x): x is string => !!x)), [tree]);
  // A port named in the address (#port-…): scrolled to once the page has it.
  useEffect(() => {
    if (!hash || !a) return;
    document.getElementById(hash)?.scrollIntoView({ block: "center" });
  }, [hash, a?.name]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!a) {
    return (
      <div className="page asset-page">
        <div className="page-head">
          <h1>{name}</h1>
          <span className="muted"><Link to="/assets">Assets</Link></span>
        </div>
        <ReadState env={r.env} failure={r.failure} what="the assets" />
        {tree ? (
          <>
            <p>No asset is recorded as {name}, and none plays a role of that name.</p>
            <p className="small">
              {v?.unplaced.some((u) => u.device === name) || t?.devices?.some((d) => d.name === name) ? <Link to={assetsSelectPath("device", name)}>The device {name} on the Assets page →</Link> : <Link to="/assets">Every asset →</Link>}
            </p>
            {operator ? <RecordDeviceButton /> : null}
          </>
        ) : null}
      </div>
    );
  }

  const kind = a.role ? roleKind(t, a.role) : null;
  const since = allocatedSince(allocations, a.role) ?? ci?.relations.find((x) => x.type === "allocated-to" && x.direction === "out")?.since ?? null;
  const roleLink = a.role ? (mods?.some((m) => m.name === a.role) ? <Link to={modulePath(a.role)}>{a.role}</Link> : <b>{a.role}</b>) : null;
  const sw = kind === "switch" ? t?.switches.find((s) => s.name === a.placedAs) : undefined;
  const ap = kind === "ap" ? t?.accessPoints.find((x) => x.name === a.placedAs) : undefined;
  const placeable = a.stage !== "ordered" && a.stage !== "disposed";
  const cabled = (v?.cables ?? []).some((c) => c.source === "recorded" && [c.from, c.to].some((e) => e.device === a.placedAs));
  const disposal = attr(ci, "disposal");
  const isDisk = a.kind === "disk";
  const host = a.in ? tree?.assets.find((x) => x.name === a.in!.asset) ?? null : null;
  const adopt = adoptOffer(a);
  const d = a.asDisk;
  return (
    <div className="page asset-page">
      <div className="page-head">
        <h1>{a.displayName ?? a.name}</h1>
        <span className="muted">
          <Link to="/assets">Assets</Link> · {a.kind}
          {a.displayName && a.displayName !== a.name ? ` · ${a.name}` : ""}
        </span>
        <StageBadge a={a} />
        <span className="spacer" />
        <Link to={viewLink("rack", a.where.rack ? `rack:${a.where.rack}` : a.where.room ? `room:${a.where.room}` : null)} className="jump jump-in">Physical view</Link>
        {kind ? <OpenIn kind={kind} id={a.placedAs} compact /> : null}
      </div>
      <ReadState env={r.env} failure={r.failure} what="the assets" />
      {a.allocationDrift ? (
        <div className="readstate readstate-warn">
          The record has it {a.role ? `playing ${a.role}` : "in no role"}; the CMDB has it {a.cmdb?.allocatedTo ? `allocated to ${a.cmdb.allocatedTo}` : "allocated to nothing"}. The next report of asset-manager brings the CMDB in line.
        </div>
      ) : null}

      <div className="grid2">
        <Section title="Record" aside="asset-manager">
          <KV
            rows={[
              ["display name", a.displayName],
              ["name", <span className="mono">{a.name}</span>],
              ["kind", a.kind],
              ["vendor", a.vendor],
              ["model", a.model],
              ["serial", a.serial ? <span className="mono">{a.serial}</span> : null],
              ...(isDisk
                ? ([
                    ["medium", [a.disk?.kind, a.disk?.bus].filter(Boolean).join(" · ") || null],
                    ["size", a.disk?.size ? bytes(a.disk.size) : null],
                    ["WWN", a.disk?.wwn ? <span className="mono">{a.disk.wwn}</span> : null],
                    ["firmware", a.disk?.firmware ?? null],
                  ] as [string, ReactNode][])
                : []),
              ["asset tag", a.assetTag ?? null],
              ["stage", <StageBadge a={a} />],
              ["faulty", a.faulty ? a.faultNote ?? "yes" : "no"],
              ["description", plain(attr(ci, "description"))],
              ["procurement", plain(attr(ci, "procurement"))],
              ["disposal", plain(disposal)],
            ]}
          />
          {!ci ? <p className="muted small">The description, procurement and disposal are read from the CMDB{rec.env?.error || rec.failure ? `, which did not answer: ${rec.env?.error ?? rec.failure}` : ""}.</p> : null}
        </Section>
        {isDisk ? (
          <Section title="Where it is">
            <KV
              rows={[
                ["in", a.in ? <>{host ? <Link to={assetPath(host.name)}>{host.displayName ?? host.name}</Link> : <span className="mono">{a.in.asset}</span>}{host?.role ? <span className="muted"> · plays {host.role}</span> : null}</> : <span className="muted">{a.stage === "disposed" ? "disposed" : "in stock: in no asset"}</span>],
                ["bay", a.in?.bay ?? null],
                ["location", a.where.location ? <LocationLink name={a.where.location} /> : null],
                ["health", d ? <><Badge level={DISK_LEVEL[d.state]}>{d.state}</Badge> <span className="muted">{healthText(d)}</span></> : null],
                ["pool", d?.pool ? poolText(d.pool) : a.in ? <span className="muted">in no pool the CMDB knows</span> : null],
              ]}
            />
            {tree?.disksError ? <p className="muted small">The CMDB's disks were not read: {tree.disksError}.</p> : null}
            {d?.pool?.node ? <p className="small"><Link to={viewLink("storage", `pool:${d.pool.node}:${d.pool.name}`)}>Its pool in the Storage view →</Link></p> : null}
          </Section>
        ) : (
        <Section title="Role and place">
          <KV
            rows={[
              ["plays", a.role ? <>{roleLink}{kind ? <span className="muted"> · {kind}</span> : null}</> : <span className="muted">no role: in stock until allocated</span>],
              ["since", since ? when(since) : null],
              ["location", a.where.location ? <LocationLink name={a.where.location} /> : null],
              ["placement", <PlacementLine v={v} device={a.placedAs} location={a.where.location || null} />],
              ["CMDB", a.cmdb ? `allocated to ${a.cmdb.allocatedTo ?? "nothing"}` : tree?.allocationsError ? <span className="muted">not read</span> : <span className="muted">no allocation</span>],
            ]}
          />
          {kind === "node" ? <p className="small"><Link to={viewLink("storage", `node:${a.placedAs}`)}>Its disks and pools in the Storage view →</Link></p> : null}
        </Section>
        )}
      </div>

      {operator ? (
        <Section title="Change">
          {isDisk ? (
            <div className="toolbar">
              <DiskOps a={a} tree={tree} />
            </div>
          ) : (
            <div className="toolbar">
              <AssetLifecycle t={t} a={a} played={played} />
              {placeable ? <PlaceActions device={a.placedAs} v={v} /> : null}
              <DeviceRecordActions name={a.name} cabled={cabled} placed={a.placed} disks={a.disks.map((x) => x.name)} />
            </div>
          )}
          {!isDisk && a.stage !== "disposed" ? (
            <div className="toolbar">
              <OperateButton label="Record a disk…" title={`A disk in ${a.name}`} steps={() => diskAddSteps(a.name)} />
              {adopt ? <OperateButton label="Adopt the disks the CMDB knows…" kind="primary" title={`Adopt ${a.name}'s disks`} steps={() => diskAdoptSteps(a.name, adopt.text)} hint={`${adopt.count} disk(s) its CMDB record lists that no asset records`} /> : null}
            </div>
          ) : null}
          {kind === "node" || sw || ap ? (
            <div className="toolbar">
              {kind === "node" ? <NodeNetwork node={a.placedAs} /> : null}
              {sw ? <DeviceLocationButton kind="switch" name={sw.name} current={sw.location ?? null} /> : null}
              {ap ? <DeviceLocationButton kind="ap" name={ap.name} current={ap.location ?? null} /> : null}
            </div>
          ) : null}
        </Section>
      ) : null}

      {isDisk ? null : (
      <Section title="Ports" aside={`${a.ports.length}`}>
        {a.ports.length === 0 ? <p className="muted">No port is recorded: its model's plate has none, and none was added.</p> : null}
        {a.ports.length ? (
          <table className="table compact small">
            <thead>
              <tr>
                <th>port</th>
                <th>connector</th>
                <th>MAC</th>
                <th>cable</th>
                {operator ? <th></th> : null}
              </tr>
            </thead>
            <tbody>
              {a.ports.map((p) => (
                <tr key={p.name} id={portAnchor(p.name)} className={hash === portAnchor(p.name) ? "row-on" : undefined}>
                  <td className="mono">{p.name}</td>
                  <td className="muted">{[p.kind, p.speed, p.standard, p.bands?.join("/"), p.module, p.role, p.side].filter(Boolean).join(" · ") || (p.listed ? "" : "only a cable names it")}</td>
                  <td className="mono">{p.mac ?? ""}</td>
                  <td>
                    {p.cables.map((c, i) => {
                      const [far, farPort] = [c.to.slice(0, c.to.lastIndexOf(":")), c.to.slice(c.to.lastIndexOf(":") + 1)];
                      const known = c.to.includes(" — ") ? null : tree?.assets.find((x) => x.placedAs === far);
                      return (
                        <div key={i}>
                          {known ? <Link to={assetPath(known.name, farPort)}>{c.to}</Link> : <span className="mono">{c.to}</span>}
                          <span className="muted"> {c.kind}{c.source === "recorded" ? " · recorded" : ""}{c.label ? ` · ${c.label}` : ""}{c.via.length ? ` · via ${c.via.join(", ")}` : ""}</span>
                        </div>
                      );
                    })}
                  </td>
                  {operator ? <td><PortOps a={a} port={p} t={t} /></td> : null}
                </tr>
              ))}
            </tbody>
          </table>
        ) : null}
      </Section>
      )}

      {isDisk ? null : (
        <Section title="Disks" aside={a.disks.length ? `${a.disks.length} · by bay` : undefined}>
          <BayRow disks={a.disks} />
          {a.disks.length ? <DiskTable a={a} tree={tree} operator={operator} /> : <p className="muted">No disk is recorded in it{adopt ? "" : ": Record a disk… records one"}.</p>}
          {adopt ? <p className="small">Its CMDB record lists {adopt.count} disk(s) no asset records: {adopt.text}. Adopt the disks the CMDB knows… records them in {a.name}.</p> : null}
          {tree?.disksError ? <p className="muted small">The CMDB's disks were not read: {tree.disksError}. Their health and pools are not shown.</p> : null}
        </Section>
      )}

      {isDisk ? (
        <Section title="Placements" aside="the assets it has been in, the newest first">
          <DiskPlacements disk={a.name} />
        </Section>
      ) : (
      <Section title="Allocations" aside="the roles it has played, the newest first">
        <ReadState env={hist.env} failure={hist.failure} what="its CMDB history" />
        {ci && hist.env?.data && allocations.length === 0 ? <p className="muted">It has played no role{a.role ? ` the CMDB has recorded (the record says ${a.role})` : ""}.</p> : null}
        {allocations.length ? (
          <table className="table compact small">
            <thead>
              <tr>
                <th>role</th>
                <th>from</th>
                <th>until</th>
                <th>source</th>
              </tr>
            </thead>
            <tbody>
              {allocations.map((x, i) => (
                <tr key={i}>
                  <td>{mods?.some((m) => m.name === x.role) ? <Link to={modulePath(x.role)}>{x.role}</Link> : x.role}</td>
                  <td className="nowrap">{when(x.from)}</td>
                  <td className="nowrap">{x.until ? when(x.until) : <span className="muted">plays it now</span>}</td>
                  <td className="muted">{x.source ?? ""}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : null}
      </Section>
      )}

      <Section title="CMDB record" aside="open events, trace, relations, history">
        <ReadState env={rec.env} failure={rec.failure} what="its CMDB record" />
        {ci ? <CiPanel start={{ id: ci.id }} embedded only={["events", "trace", "drift", "relations", "history"]} /> : null}
      </Section>
    </div>
  );
}
